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
//! - `masm_flow_dap_variables` (Tier 2): Breakpoint in `arithmetic` proc, verifies
//!   basic and u32checked arithmetic results across 6 locals.
//! - `masm_flow_dap_loop_variables` (Tier 2): Breakpoint inside `sum_loop` while body,
//!   verifies counter and accumulator locals during iteration.
//! - `masm_flow_dap_conditional_variables` (Tier 2): Breakpoint after if/else in
//!   `conditional_branch`, verifies branch-dependent local values.
//! - `masm_flow_dap_nested_calls` (Tier 2): Breakpoint in `nested_outer` after
//!   fibonacci and conditional_branch calls, verifies combined results.
//! - `masm_flow_dap_memory_ops` (Tier 2): Breakpoint in `memory_ops`, verifies
//!   locals derived from global memory (mem_store/mem_load).
//! - `masm_flow_dap_fibonacci` (Tier 2): Breakpoint at end of `fibonacci` proc,
//!   verifies iterative Fibonacci result locals.
//! - `masm_flow_dap_bitwise` (Tier 2): Breakpoint in `bitwise_ops`, verifies
//!   u32checked_and, u32checked_or, u32checked_xor results.
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

/// Shared helper that records a MASM trace, launches the DAP server, sets a
/// breakpoint at the given line, and verifies that the expected locals appear
/// with the correct values.
///
/// # Arguments
///
/// * `breakpoint_line` - Source line where the breakpoint is placed.
/// * `expected_variables` - Local variable names that SHOULD appear in flow data.
/// * `expected_values` - Map of variable name to expected integer value.
/// * `excluded` - Identifiers that should NOT appear (e.g. procedure names).
fn run_masm_dap_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    expected_values: HashMap<String, i64>,
    excluded: Vec<&str>,
) {
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
        .expect("MASM recording failed -- check that codetracer-miden-recorder is available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The Miden recorder copies the source file into trace_dir and stores just
    // the filename in trace_paths.json (workdir = trace_dir). Use the
    // trace_dir copy path for the breakpoint so that path lookup succeeds.
    let source_copy = recording.trace_dir.join(source_path.file_name().unwrap());

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: expected_variables.into_iter().map(String::from).collect(),
        excluded_identifiers: excluded.into_iter().map(String::from).collect(),
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for MASM trace");
    runner.run_and_verify(&config).expect("MASM flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("MASM DAP flow test passed!");
}

/// Tier 2 (DAP flow): Breakpoint in the `arithmetic` procedure after all 6
/// locals are assigned.
///
/// Expected local variables at line 143 (`u32checked_mul loc_store.5`):
///   local[0] = 7   (a)
///   local[1] = 3   (b)
///   local[2] = 10  (a + b)
///   local[3] = 21  (a * b)
///   local[4] = 10  (u32checked_add)
///   local[5] = 21  (u32checked_mul)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 7);
    expected_values.insert("local[1]".to_string(), 3);
    expected_values.insert("local[2]".to_string(), 10);
    expected_values.insert("local[3]".to_string(), 21);
    expected_values.insert("local[4]".to_string(), 10);
    expected_values.insert("local[5]".to_string(), 21);

    run_masm_dap_test(
        143,
        vec!["local[0]", "local[1]", "local[2]", "local[3]", "local[4]", "local[5]"],
        expected_values,
        vec!["exec", "arithmetic"],
    );
}

/// Tier 2 (DAP flow): Breakpoint inside the `sum_loop` while body at the
/// accumulator update line. We verify that counter and accumulator locals
/// have values consistent with at least one loop iteration having executed.
///
/// Breakpoint at line 94 (`loc_load.2 loc_load.1 add loc_store.2`):
/// After the first iteration completes:
///   local[0] = 5   (N, the limit)
///   local[1] = 1   (counter after first increment)
///   local[2] = 1   (accumulator: 0 + 1)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_loop_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 5);
    expected_values.insert("local[1]".to_string(), 1);
    expected_values.insert("local[2]".to_string(), 1);

    run_masm_dap_test(
        94,
        vec!["local[0]", "local[1]", "local[2]"],
        expected_values,
        vec!["exec", "sum_loop"],
    );
}

/// Tier 2 (DAP flow): Breakpoint after the if/else in `conditional_branch`.
/// The entry point calls this with value 75 (> 50), so the if-branch is taken.
///
/// Expected local variables at line 63 (`loc_load.1`):
///   local[0] = 75  (input value)
///   local[1] = 150 (75 * 2, if-branch taken)
///   local[2] = 1   (branch indicator: if-branch)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_conditional_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 75);
    expected_values.insert("local[1]".to_string(), 150);
    expected_values.insert("local[2]".to_string(), 1);

    run_masm_dap_test(
        63,
        vec!["local[0]", "local[1]", "local[2]"],
        expected_values,
        vec!["exec", "conditional_branch"],
    );
}

/// Tier 2 (DAP flow): Breakpoint in `nested_outer` after both fibonacci and
/// conditional_branch calls complete and results are combined.
///
/// Expected local variables at line 126 (`loc_load.0 loc_load.1 add loc_store.2`):
///   local[0] = 55  (fib(10))
///   local[1] = 110 (55 > 50, so 55 * 2 = 110)
///   local[2] = 165 (55 + 110)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_nested_calls() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 55);
    expected_values.insert("local[1]".to_string(), 110);
    expected_values.insert("local[2]".to_string(), 165);

    run_masm_dap_test(
        126,
        vec!["local[0]", "local[1]", "local[2]"],
        expected_values,
        vec!["exec", "nested_outer", "fibonacci", "conditional_branch"],
    );
}

/// Tier 2 (DAP flow): Breakpoint in `memory_ops` after all memory stores and
/// loads are complete.
///
/// Expected local variables at line 77 (`loc_load.2 push.2 mul loc_store.3`):
///   local[0] = 111 (stored at mem[0])
///   local[1] = 222 (stored at mem[1])
///   local[2] = 333 (mem[0] + mem[1] = 111 + 222)
///   local[3] = 666 (333 * 2)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_memory_ops() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 111);
    expected_values.insert("local[1]".to_string(), 222);
    expected_values.insert("local[2]".to_string(), 333);
    expected_values.insert("local[3]".to_string(), 666);

    run_masm_dap_test(
        77,
        vec!["local[0]", "local[1]", "local[2]", "local[3]"],
        expected_values,
        vec!["exec", "memory_ops"],
    );
}

/// Tier 2 (DAP flow): Breakpoint at the end of the `fibonacci` procedure
/// after the iterative computation completes.
///
/// The loop uses `lte` so it runs while counter <= N. With N=10, the loop
/// executes 9 iterations (counter goes from 2 to 11).
///
/// Expected local variables at line 44 (`loc_load.2`):
///   local[0] = 10  (N)
///   local[1] = 34  (prev: fib(9))
///   local[2] = 55  (curr: fib(10), the result)
///   local[3] = 55  (next: same as curr after last iteration)
///   local[4] = 11  (counter: N + 1 after loop exit)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_fibonacci() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 10);
    expected_values.insert("local[2]".to_string(), 55);
    expected_values.insert("local[4]".to_string(), 11);

    run_masm_dap_test(
        44,
        vec!["local[0]", "local[1]", "local[2]", "local[3]", "local[4]"],
        expected_values,
        vec!["exec", "fibonacci"],
    );
}

/// Tier 2 (DAP flow): Breakpoint in `bitwise_ops` after all bitwise
/// operations complete.
///
/// Inputs: a = 255 (0xFF), b = 15 (0x0F)
/// Expected local variables at line 17 (`u32checked_xor loc_store.4`):
///   local[0] = 255 (a)
///   local[1] = 15  (b)
///   local[2] = 15  (0xFF AND 0x0F = 0x0F)
///   local[3] = 255 (0xFF OR 0x0F = 0xFF)
///   local[4] = 240 (0xFF XOR 0x0F = 0xF0)
#[test]
#[ignore = "requires miden-recorder; run via: just test-masm-flow"]
fn masm_flow_dap_bitwise() {
    let mut expected_values = HashMap::new();
    expected_values.insert("local[0]".to_string(), 255);
    expected_values.insert("local[1]".to_string(), 15);
    expected_values.insert("local[2]".to_string(), 15);
    expected_values.insert("local[3]".to_string(), 255);
    expected_values.insert("local[4]".to_string(), 240);

    run_masm_dap_test(
        17,
        vec!["local[0]", "local[1]", "local[2]", "local[3]", "local[4]"],
        expected_values,
        vec!["exec", "bitwise_ops"],
    );
}
