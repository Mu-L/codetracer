//! Headless DAP flow test for Miden/MASM traces.
//!
//! This test verifies that the DAP server correctly handles MASM traces
//! produced by the codetracer-miden-recorder. It follows the same pattern as
//! `solidity_flow_dap_test.rs`, but targets the Miden/MASM recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-miden-recorder` binary (set `CODETRACER_MIDEN_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-miden-recorder/`)
//!
//! ## Test tiers
//!
//! - `masm_flow_dap_variables` (Tier 2): Records a trace of
//!   `masm_flow_test.masm`, launches the DAP server, sets a breakpoint at the
//!   final `loc_store.4` instruction, and verifies the expected local variables
//!   appear in flow data.
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run masm_flow_dap`
//! or:
//!   `just test-masm-flow`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_miden_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the MASM flow test source file.
fn get_masm_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/masm/masm_flow_test.masm")
}

/// Tier 2 (DAP flow): Record a MASM trace and verify that the DAP server can
/// set a breakpoint, continue to it, and extract the expected local variables
/// from the flow data.
///
/// Expected local variables at line 6 (`loc_store.4` instruction):
///   local[0] = 10
///   local[1] = 32
///   local[2] = 42  (10 + 32)
///   local[3] = 84  (42 * 2)
///   local[4] = 94  (84 + 10)
///
/// Prerequisites: `codetracer-miden-recorder`.
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_variables() {
    // --- Prerequisite checks ---
    assert!(
        find_miden_recorder().is_some(),
        "Miden recorder not found. \
         Set CODETRACER_MIDEN_RECORDER_PATH or build codetracer-miden-recorder \
         (run `cargo build` inside the codetracer-miden-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_masm_source_path();

    assert!(
        source_path.exists(),
        "MASM test program not found at {}",
        source_path.display()
    );

    // Record the MASM trace via the Miden recorder CLI.
    let recording = TestRecording::create_db_trace(&source_path, Language::Masm, "masm-0.13")
        .expect("MASM recording failed — check that codetracer-miden-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Miden recorder copies the source file into trace_dir and stores just
    // the filename in trace_paths.json (workdir = trace_dir). Use the
    // trace_dir copy path for the breakpoint so that path lookup succeeds.
    let source_copy = recording.trace_dir.join(source_path.file_name().unwrap());

    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 10);
    expected_values.insert("local[1]".to_string(), 32);
    expected_values.insert("local[2]".to_string(), 42);
    expected_values.insert("local[3]".to_string(), 84);
    expected_values.insert("local[4]".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 6: `loc_load.3 loc_load.0 add loc_store.4` — all 5 locals are set.
        breakpoint_line: 6,
        expected_variables: vec!["local[0]", "local[1]", "local[2]", "local[3]", "local[4]"]
            .into_iter()
            .map(String::from)
            .collect(),
        // `exec` and `compute` are procedure names, not variables
        excluded_identifiers: vec!["exec".to_string(), "compute".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for MASM trace");
    runner.run_and_verify(&config).expect("MASM flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("MASM DAP flow test passed!");
}
