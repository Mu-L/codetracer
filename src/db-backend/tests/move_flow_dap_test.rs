//! Headless DAP flow test for Move/Sui traces.
//!
//! This test verifies that the DAP server correctly handles Move traces
//! produced by the codetracer-move-recorder. It follows the same pattern as
//! `solidity_flow_dap_test.rs`, but targets the Move/Sui recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-move-recorder` binary (set `CODETRACER_MOVE_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-move-recorder/`)
//!
//! ## Test tiers
//!
//! - `move_flow_dap_variables` (Tier 2): Records a trace of the Move
//!   `flow_test` module test, launches the DAP server, sets a breakpoint at
//!   the final assertion, and verifies the expected local variables appear in
//!   flow data.
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run move_flow_dap`
//! or:
//!   `just test-move-flow`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_move_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Move flow test project directory.
///
/// For Move, the source_path is the project directory containing `Move.toml`,
/// not a single source file. The recorder discovers source files from the
/// project manifest.
fn get_move_project_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/move/flow_test")
}

/// Returns the path to the Move source file (for breakpoint setting).
fn get_move_source_path() -> PathBuf {
    get_move_project_path().join("sources/flow_test.move")
}

/// Tier 2 (DAP flow): Record a Move trace and verify that the DAP server can
/// set a breakpoint, continue to it, and extract the expected local variables
/// from the flow data.
///
/// Expected local variables inside `test_computation()` at line 10
/// (`final_result` assignment):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
///
/// Note: Variable names may appear as `local_0` through `local_4` depending
/// on the Move trace format output. The test checks for whichever
/// representation the recorder produces.
///
/// Prerequisites: `codetracer-move-recorder`.
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_variables() {
    // --- Prerequisite checks ---
    assert!(
        find_move_recorder().is_some(),
        "Move recorder not found. \
         Set CODETRACER_MOVE_RECORDER_PATH or build codetracer-move-recorder \
         (run `cargo build` inside the codetracer-move-recorder repo)."
    );

    let db_backend = find_db_backend();
    let project_path = get_move_project_path();
    let source_path = get_move_source_path();

    assert!(
        project_path.join("Move.toml").exists(),
        "Move test project not found at {}",
        project_path.display()
    );

    // Record the Move trace via the Move recorder CLI.
    // Pass the project directory (containing Move.toml) as source_path.
    let recording = TestRecording::create_db_trace(&project_path, Language::Move, "move-2024")
        .expect("Move recording failed — check that codetracer-move-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Move recorder may copy the source file into trace_dir. Check for it,
    // otherwise fall back to the original source path.
    let source_in_trace = recording.trace_dir.join("flow_test.move");
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
        // Line 10: `let final_result: u64 = doubled + a;` — all 5 locals are in scope.
        breakpoint_line: 10,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // `assert!` and `test_computation` are not variables
        excluded_identifiers: vec!["assert!".to_string(), "test_computation".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Move trace");
    runner.run_and_verify(&config).expect("Move flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Move DAP flow test passed!");
}
