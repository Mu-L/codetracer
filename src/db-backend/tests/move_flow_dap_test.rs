//! Headless DAP flow tests for Move/Sui traces.
//!
//! These tests verify that the DAP server correctly handles Move traces
//! produced by the codetracer-move-recorder. Each test targets a different
//! set of Move language constructs in the comprehensive `flow_test` module.
//!
//! ## Prerequisites
//!
//! - `codetracer-move-recorder` binary (set `CODETRACER_MOVE_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-move-recorder/`)
//!
//! ## Test tiers
//!
//! All tests are Tier 2 (DAP flow): they record a trace, launch the DAP server,
//! set breakpoints at specific lines, and verify expected local variables.
//!
//! - `move_flow_dap_variables` — basic arithmetic (u64)
//! - `move_flow_dap_struct_variables` — struct creation, field access, destructuring
//! - `move_flow_dap_vector_ops` — vector push/pop/borrow/length
//! - `move_flow_dap_loop_variables` — while loops, loop/break, conditionals
//! - `move_flow_dap_nested_calls` — nested function calls, tuple returns, constants
//! - `move_flow_dap_generic_function` — generic Container<T> with different types
//! - `move_flow_dap_fibonacci` — iterative Fibonacci computation
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
use test_harness::{find_move_flow_source, find_move_flow_test, find_move_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Move flow test project directory.
///
/// Discovers the test project from the sibling `codetracer-move-recorder` repo
/// (canonical location per Test-Program-Layout.md), falling back to the local
/// `test-programs/` directory if the sibling is not available.
///
/// For Move, the source_path is the project directory containing `Move.toml`,
/// not a single source file. The recorder discovers source files from the
/// project manifest.
fn get_move_project_path() -> PathBuf {
    find_move_flow_test().expect(
        "Move flow test project not found. \
         Check out codetracer-move-recorder as a sibling repo, or ensure \
         test-programs/move/flow_test/ exists locally.",
    )
}

/// Returns the path to the Move source file (for breakpoint setting).
///
/// Uses the same sibling-repo discovery as `get_move_project_path()`.
fn get_move_source_path() -> PathBuf {
    find_move_flow_source().expect(
        "Move flow test source not found. \
         Check out codetracer-move-recorder as a sibling repo, or ensure \
         test-programs/move/flow_test/sources/flow_test.move exists locally.",
    )
}

/// Shared setup: verify prerequisites, record a trace, and resolve the
/// breakpoint source path (which may be inside the trace directory).
///
/// Returns `(db_backend_path, trace_recording, breakpoint_source_path)`.
///
/// # Panics
///
/// Panics if the Move recorder is not found, the project directory is missing,
/// or recording fails.
fn setup_move_trace() -> (PathBuf, TestRecording, PathBuf) {
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

    (db_backend, recording, breakpoint_source)
}

/// Run a single DAP flow test with the given configuration.
///
/// This helper records a trace (via `setup_move_trace`), creates a
/// `FlowTestRunner`, executes `run_and_verify`, and disconnects.
fn run_move_flow_test(
    breakpoint_line: usize,
    expected_variables: Vec<&str>,
    excluded_identifiers: Vec<&str>,
    expected_values: HashMap<String, i64>,
) {
    let (db_backend, recording, breakpoint_source) = setup_move_trace();

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        breakpoint_line,
        expected_variables: expected_variables.into_iter().map(String::from).collect(),
        excluded_identifiers: excluded_identifiers.into_iter().map(String::from).collect(),
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Move trace");
    runner.run_and_verify(&config).expect("Move flow DAP test failed");
    runner.finish().expect("disconnect failed");
}

// ---------------------------------------------------------------------------
// Test: basic arithmetic variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify basic u64 arithmetic variables in
/// `test_computation()` at line 141 where `final_result` is assigned.
///
/// Expected locals:
///   a            = 10
///   b            = 32
///   sum_val      = 42   (a + b)
///   doubled      = 84   (sum_val * 2)
///   final_result = 94   (doubled + a)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    run_move_flow_test(
        141, // line: let final_result: u64 = doubled + a;
        vec!["a", "b", "sum_val", "doubled", "final_result"],
        vec!["assert!", "test_computation"],
        expected_values,
    );

    println!("Move DAP flow test (variables) passed!");
}

// ---------------------------------------------------------------------------
// Test: struct creation, field access, destructuring
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify struct-related variables in `test_structs()`
/// at line 168 after destructuring `sum_point` into `px` and `py`.
///
/// Expected locals at the breakpoint:
///   px         = 10  (sum_point.x after add_points)
///   py         = 10  (sum_point.y after add_points)
///   sum_coords = 20  (px + py)
///   area       = 40  (rectangle 5x8)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_struct_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("px".to_string(), 10);
    expected_values.insert("py".to_string(), 10);
    expected_values.insert("sum_coords".to_string(), 20);
    expected_values.insert("area".to_string(), 40);

    run_move_flow_test(
        168, // line: assert!(sum_coords == 20, ...)
        vec!["px", "py", "sum_coords", "area"],
        vec!["assert!", "test_structs", "add_points", "rectangle_area"],
        expected_values,
    );

    println!("Move DAP flow test (struct variables) passed!");
}

// ---------------------------------------------------------------------------
// Test: vector operations
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify vector operation results in `test_vectors()`
/// at line 206 after popping the last element.
///
/// Expected locals at the breakpoint:
///   len     = 5   (original length)
///   first   = 10  (v[0])
///   last    = 50  (v[4])
///   sum     = 150 (10+20+30+40+50)
///   popped  = 50  (pop_back result)
///   new_len = 4   (length after pop)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_vector_ops() {
    let mut expected_values = HashMap::new();
    expected_values.insert("len".to_string(), 5);
    expected_values.insert("first".to_string(), 10);
    expected_values.insert("last".to_string(), 50);
    expected_values.insert("sum".to_string(), 150);
    expected_values.insert("popped".to_string(), 50);
    expected_values.insert("new_len".to_string(), 4);

    run_move_flow_test(
        208, // line: assert!(popped == 50, ...) — all vector locals in scope
        vec!["len", "first", "last", "sum", "popped", "new_len"],
        vec!["assert!", "test_vectors", "vector_sum"],
        expected_values,
    );

    println!("Move DAP flow test (vector ops) passed!");
}

// ---------------------------------------------------------------------------
// Test: loops and control flow
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify loop variables in `test_loops()` at line 240
/// after both the while loop and loop/break have completed.
///
/// Expected locals at the breakpoint:
///   counter     = 10  (while loop ran 10 iterations)
///   accumulator = 55  (sum of 1..10)
///   power       = 128 (first power of 2 >= 100)
///   iterations  = 7   (2^7 = 128)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_loop_variables() {
    let mut expected_values = HashMap::new();
    expected_values.insert("counter".to_string(), 10);
    expected_values.insert("accumulator".to_string(), 55);
    expected_values.insert("power".to_string(), 128);
    expected_values.insert("iterations".to_string(), 7);

    run_move_flow_test(
        240, // line: assert!(power == 128, ...) — after both loops complete
        vec!["counter", "accumulator", "power", "iterations"],
        vec!["assert!", "test_loops"],
        expected_values,
    );

    println!("Move DAP flow test (loop variables) passed!");
}

// ---------------------------------------------------------------------------
// Test: nested function calls and tuple returns
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify nested call results in `test_nested_calls()`
/// at line 265 after `compute_triple` returns and nested min/max calls.
///
/// Expected locals at the breakpoint:
///   x       = 12
///   y       = 8
///   sum     = 20  (12 + 8)
///   product = 96  (12 * 8)
///   max     = 12  (max of 12, 8)
///   nested_result = 15  (max(min(12,8), min(15,20)) = max(8, 15) = 15)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_nested_calls() {
    let mut expected_values = HashMap::new();
    expected_values.insert("x".to_string(), 12);
    expected_values.insert("y".to_string(), 8);
    expected_values.insert("sum".to_string(), 20);
    expected_values.insert("product".to_string(), 96);
    expected_values.insert("max".to_string(), 12);
    expected_values.insert("nested_result".to_string(), 15);

    run_move_flow_test(
        267, // line: assert!(nested_result == 15, ...) — after nested calls
        vec!["x", "y", "sum", "product", "max", "nested_result"],
        vec!["assert!", "test_nested_calls", "compute_triple", "max_u64", "min_u64"],
        expected_values,
    );

    println!("Move DAP flow test (nested calls) passed!");
}

// ---------------------------------------------------------------------------
// Test: generic functions
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify generic function results in `test_generics()`
/// at line 299 after wrapping/unwrapping a Point in a Container.
///
/// Expected locals at the breakpoint:
///   v1              = 42  (unwrapped u64 from Container<u64>)
///   container_label = 3   (Container<Point> label)
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_generic_function() {
    let mut expected_values = HashMap::new();
    expected_values.insert("v1".to_string(), 42);
    expected_values.insert("container_label".to_string(), 3);

    run_move_flow_test(
        301, // line: assert!(container_label == 3, ...) — after generic ops
        vec!["v1", "container_label"],
        vec!["assert!", "test_generics", "wrap_value", "unwrap_value"],
        expected_values,
    );

    println!("Move DAP flow test (generic function) passed!");
}

// ---------------------------------------------------------------------------
// Test: Fibonacci computation
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify Fibonacci results in `test_fibonacci()` at
/// line 317 after all five Fibonacci values have been computed.
///
/// Expected locals at the breakpoint:
///   fib_0  = 0
///   fib_1  = 1
///   fib_5  = 5
///   fib_10 = 55
///   fib_15 = 610
#[test]
#[ignore = "requires move-recorder; run via: just test-move-flow"]
fn move_flow_dap_fibonacci() {
    let mut expected_values = HashMap::new();
    expected_values.insert("fib_0".to_string(), 0);
    expected_values.insert("fib_1".to_string(), 1);
    expected_values.insert("fib_5".to_string(), 5);
    expected_values.insert("fib_10".to_string(), 55);
    expected_values.insert("fib_15".to_string(), 610);

    run_move_flow_test(
        317, // line: assert!(fib_0 == 0, ...) — all fib values computed
        vec!["fib_0", "fib_1", "fib_5", "fib_10", "fib_15"],
        vec!["assert!", "test_fibonacci", "fibonacci"],
        expected_values,
    );

    println!("Move DAP flow test (fibonacci) passed!");
}
