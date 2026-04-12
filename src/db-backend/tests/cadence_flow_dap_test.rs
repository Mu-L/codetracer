//! Headless DAP flow test for Cadence/Flow traces.
//!
//! This test verifies that the DAP server correctly handles Cadence traces
//! produced by the codetracer-flow-recorder. It follows the same pattern as
//! `masm_flow_dap_test.rs`, but targets the Cadence/Flow recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-flow-recorder` binary (set `CODETRACER_CADENCE_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-flow-recorder/`)
//!
//! ## Test tiers
//!
//! - `cadence_flow_dap_variables` (Tier 2): Breakpoint in `compute()` fn, verifies
//!   basic arithmetic results across 5 locals.
//!
//! Run with:
//!   `cargo nextest run cadence_flow_dap`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_cadence_flow_test, find_cadence_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Cadence flow test source file.
fn get_cadence_source_path() -> PathBuf {
    find_cadence_flow_test().expect(
        "Cadence flow test program not found. \
         Check out codetracer-flow-recorder as a sibling repo, or ensure \
         test-programs/cadence/flow_test.cdc exists locally.",
    )
}

/// Shared helper that records a Cadence trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected locals appear
/// with the correct values.
fn run_cadence_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
    assert!(
        find_cadence_recorder().is_some(),
        "Cadence/Flow recorder not found. \
         Set CODETRACER_CADENCE_RECORDER_PATH or build codetracer-flow-recorder \
         (run `cargo build` inside the codetracer-flow-recorder repo)."
    );

    let db_backend = find_db_backend();
    let source_path = get_cadence_source_path();

    assert!(
        source_path.exists(),
        "Cadence test program not found at {}",
        source_path.display()
    );

    let recording = TestRecording::create_db_trace(&source_path, Language::Cadence, "cadence-1.0")
        .expect("Cadence recording failed -- check that codetracer-flow-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // Use the original source path — the trace stores the absolute path as recorded,
    // not the trace-dir copy.
    let config = FlowTestConfig {
        source_file: source_path.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: expected_variables.into_iter().map(String::from).collect(),
        excluded_identifiers: excluded.into_iter().map(String::from).collect(),
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Cadence trace");
    runner.run_and_verify(&config).expect("Cadence flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Cadence DAP flow test passed!");
}

/// Tier 2 (DAP flow): Breakpoint in the `compute()` function after all 5
/// locals are assigned.
///
/// Expected local variables at line 6 (`let final_result`):
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
#[test]
#[ignore = "requires flow-recorder; run via: just test-cadence-flow"]
fn cadence_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    run_cadence_dap_test(
        6,
        vec!["a", "b", "sum_val", "doubled", "final_result"],
        expected_values,
        vec!["compute", "main"],
    );
}
