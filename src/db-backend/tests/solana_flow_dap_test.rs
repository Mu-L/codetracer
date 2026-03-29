//! Headless DAP flow test for Solana/SBF traces.
//!
//! This test verifies that the DAP server correctly handles Solana traces
//! produced by the codetracer-solana-recorder. It follows the same pattern as
//! `solidity_flow_dap_test.rs`, but targets the Solana/SBF recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-solana-recorder` binary (set `CODETRACER_SOLANA_RECORDER_PATH`
//!   or build it in the sibling repo `codetracer-solana-recorder/`)
//!
//! ## Test tiers
//!
//! - `solana_flow_dap_variables` (Tier 2): Records a trace of
//!   `solana_flow_test.rs`, launches the DAP server, sets a breakpoint at the
//!   final assignment, and verifies the expected local variables appear in
//!   flow data.
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run solana_flow_dap`
//! or:
//!   `just test-solana-flow`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_solana_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Solana flow test source file.
fn get_solana_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/solana/solana_flow_test.rs")
}

/// Tier 2 (DAP flow): Record a Solana trace and verify that the DAP server can
/// set a breakpoint, continue to it, and extract the expected local variables
/// from the flow data.
///
/// Expected local variables inside `process_instruction()` at line 10
/// (`final_result` assignment):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
///
/// Note: Variable names may appear as register names (r1-r5) depending on the
/// Solana trace format. The test checks for whichever representation the
/// recorder produces.
///
/// Prerequisites: `codetracer-solana-recorder`.
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_variables() {
    // --- Prerequisite checks ---
    assert!(
        find_solana_recorder().is_some(),
        "Solana recorder not found. \
         Set CODETRACER_SOLANA_RECORDER_PATH or build codetracer-solana-recorder \
         (run `cargo build` inside the codetracer-solana-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_solana_source_path();

    assert!(
        source_path.exists(),
        "Solana test program not found at {}",
        source_path.display()
    );

    // Record the Solana trace via the Solana recorder CLI.
    let recording = TestRecording::create_db_trace(&source_path, Language::Solana, "solana-1.18")
        .expect("Solana recording failed — check that codetracer-solana-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Solana recorder copies the source file into trace_dir and stores just
    // the filename in trace_paths.json (workdir = trace_dir). Use the
    // trace_dir copy path for the breakpoint so that path lookup succeeds.
    let source_copy = recording.trace_dir.join(source_path.file_name().unwrap());

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 10: `let final_result: u64 = doubled + a;` — all 5 locals are in scope.
        breakpoint_line: 10,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // `process_instruction` is a function name, not a variable
        excluded_identifiers: vec!["process_instruction".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Solana trace");
    runner.run_and_verify(&config).expect("Solana flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Solana DAP flow test passed!");
}
