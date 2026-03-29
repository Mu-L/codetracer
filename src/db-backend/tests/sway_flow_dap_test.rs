//! Headless DAP flow test for Sway/FuelVM traces.
//!
//! This test verifies that the DAP server correctly handles Sway traces
//! produced by the codetracer-fuel-recorder. It follows the same pattern as
//! `solidity_flow_dap_test.rs`, but targets the Sway/FuelVM recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-fuel-recorder` binary (set `CODETRACER_FUEL_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-fuel-recorder/`)
//! - `forc` (Fuel compiler) on PATH
//!
//! ## Test tiers
//!
//! - `sway_flow_dap_variables` (Tier 2): Records a trace of the Sway
//!   `flow_test` script, launches the DAP server, sets a breakpoint at the
//!   final assignment, and verifies the expected local variables appear in
//!   flow data.
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run sway_flow_dap`
//! or:
//!   `just test-sway-flow`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_fuel_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Sway flow test project directory.
///
/// For Sway, the source_path is the project directory containing `Forc.toml`,
/// not a single source file. The recorder discovers `src/main.sw` from the
/// project manifest.
fn get_sway_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/sway/flow_test")
}

/// Returns the path to the Sway source file (for breakpoint setting).
fn get_sway_source_path() -> PathBuf {
    get_sway_project_path().join("src/main.sw")
}

/// Tier 2 (DAP flow): Record a Sway trace and verify that the DAP server can
/// set a breakpoint, continue to it, and extract the expected local variables
/// from the flow data.
///
/// Expected local variables inside `main()` at line 8 (`final_result`
/// assignment):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
///
/// Note: Variable names may appear as register names (r16-r20) if Sway source
/// maps are not yet integrated. The test checks for whichever representation
/// the recorder produces.
///
/// Prerequisites: `codetracer-fuel-recorder`, `forc` (Fuel compiler).
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_variables() {
    // --- Prerequisite checks ---
    assert!(
        find_fuel_recorder().is_some(),
        "Fuel recorder not found. \
         Set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder \
         (run `cargo build` inside the codetracer-fuel-recorder repo)."
    );

    let db_backend = find_db_backend();
    let project_path = get_sway_project_path();
    let source_path = get_sway_source_path();

    assert!(
        project_path.join("Forc.toml").exists(),
        "Sway test project not found at {}",
        project_path.display()
    );

    // Record the Sway trace via the Fuel recorder CLI.
    // Pass the project directory (containing Forc.toml) as source_path.
    let recording = TestRecording::create_db_trace(&project_path, Language::Sway, "sway-0.66")
        .expect("Sway recording failed — check that codetracer-fuel-recorder and forc are available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Fuel recorder may copy the source file into trace_dir. Check for it,
    // otherwise fall back to the original source path.
    let source_in_trace = recording.trace_dir.join("main.sw");
    let breakpoint_source = if source_in_trace.exists() {
        source_in_trace
    } else {
        source_path
    };

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 8: `let final_result: u64 = doubled + a;` — all 5 locals are in scope.
        breakpoint_line: 8,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // `main` is a function name, not a variable
        excluded_identifiers: vec!["main".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Sway trace");
    runner.run_and_verify(&config).expect("Sway flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Sway DAP flow test passed!");
}
