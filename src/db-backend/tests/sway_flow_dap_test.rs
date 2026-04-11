//! Headless DAP flow tests for Sway/FuelVM traces.
//!
//! These tests verify that the DAP server correctly handles Sway traces
//! produced by the codetracer-fuel-recorder. Each test focuses on a different
//! set of Sway language constructs:
//!
//!   - `sway_flow_dap_variables`      — basic arithmetic locals
//!   - `sway_flow_dap_struct_variables` — struct creation and field access
//!   - `sway_flow_dap_enum_match`     — enum construction and pattern matching
//!   - `sway_flow_dap_loop_variables` — while-loop accumulators
//!   - `sway_flow_dap_nested_calls`   — nested / chained function calls
//!   - `sway_flow_dap_array_tuple`    — array indexing and tuple destructuring
//!   - `sway_flow_dap_fibonacci`      — iterative fibonacci computation
//!
//! ## Prerequisites
//!
//! - `codetracer-fuel-recorder` binary (set `CODETRACER_FUEL_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-fuel-recorder/`)
//! - `forc` (Fuel compiler) on PATH
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run sway_flow_dap`
//! or:
//!   `just test-sway-flow`

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_fuel_recorder, find_sway_flow_source, find_sway_flow_test, Language, TestRecording};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Sway flow test project directory.
///
/// Discovers the test project from the sibling `codetracer-fuel-recorder` repo
/// (canonical location per Test-Program-Layout.md), falling back to the local
/// `test-programs/` directory if the sibling is not available.
///
/// For Sway, the source_path is the project directory containing `Forc.toml`,
/// not a single source file. The recorder discovers `src/main.sw` from the
/// project manifest.
fn get_sway_project_path() -> PathBuf {
    find_sway_flow_test().expect(
        "Sway flow test project not found. \
         Check out codetracer-fuel-recorder as a sibling repo, or ensure \
         test-programs/sway/flow_test/ exists locally.",
    )
}

/// Returns the path to the Sway source file (for breakpoint setting).
///
/// Uses the same sibling-repo discovery as `get_sway_project_path()`.
fn get_sway_source_path() -> PathBuf {
    find_sway_flow_source().expect(
        "Sway flow test source not found. \
         Check out codetracer-fuel-recorder as a sibling repo, or ensure \
         test-programs/sway/flow_test/src/main.sw exists locally.",
    )
}

/// Common setup for all Sway DAP tests: asserts prerequisites, records a trace,
/// and returns the `(db_backend, recording, breakpoint_source)` triple.
///
/// Panics with a descriptive message if the Fuel recorder or project directory
/// is not available.
fn setup_sway_trace() -> (PathBuf, TestRecording, PathBuf) {
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

    (db_backend, recording, breakpoint_source)
}

/// Run a single DAP flow test with the given configuration.
///
/// Creates a `FlowTestRunner`, executes `run_and_verify`, and disconnects.
fn run_dap_test(db_backend: &Path, recording: &TestRecording, config: &FlowTestConfig) {
    let mut runner =
        FlowTestRunner::new_db_trace(db_backend, &recording.trace_dir).expect("DAP init failed for Sway trace");
    runner.run_and_verify(config).expect("Sway flow DAP test failed");
    runner.finish().expect("disconnect failed");
}

// ---------------------------------------------------------------------------
// Test 1: Basic arithmetic variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify basic arithmetic locals in `main()`.
///
/// Breakpoint at line 212 (`log(final_result)`) where Section 1 locals are:
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (double(sum_val))
///   final_result = 94  (doubled + a)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_variables() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 212: `log(final_result);` — all 5 Section 1 locals are in scope.
        breakpoint_line: 212,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["main".to_string(), "log".to_string()],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_variables passed!");
}

// ---------------------------------------------------------------------------
// Test 2: Struct variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify struct creation and field-derived locals.
///
/// Breakpoint at line 224 (`log(struct_sum)`) where Section 2 locals include:
///   area       = 50   (rect width * height = 10 * 5)
///   dist       = 10   (origin.x + origin.y = 3 + 7)
///   struct_sum = 60   (area + dist)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_struct_variables() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("area".to_string(), 50);
    expected_values.insert("dist".to_string(), 10);
    expected_values.insert("struct_sum".to_string(), 60);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 224: `log(struct_sum);` — struct-derived locals are in scope.
        breakpoint_line: 224,
        expected_variables: vec!["area", "dist", "struct_sum"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "main".to_string(),
            "log".to_string(),
            "rect_area".to_string(),
            "manhattan_distance".to_string(),
        ],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_struct_variables passed!");
}

// ---------------------------------------------------------------------------
// Test 3: Enum and pattern matching
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify enum construction and pattern-match results.
///
/// Breakpoint at line 234 (`log(match_sum)`) where Section 3 locals include:
///   unwrapped_some = 99   (MaybeU64::Some(99) unwrapped)
///   unwrapped_none = 42   (MaybeU64::None with default 42)
///   dir_code       = 3    (Direction::East => 3)
///   match_sum      = 102  (unwrapped_some + dir_code)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_enum_match() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("unwrapped_some".to_string(), 99);
    expected_values.insert("unwrapped_none".to_string(), 42);
    expected_values.insert("dir_code".to_string(), 3);
    expected_values.insert("match_sum".to_string(), 102);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 234: `log(match_sum);` — enum/match locals are in scope.
        breakpoint_line: 234,
        expected_variables: vec!["unwrapped_some", "unwrapped_none", "dir_code", "match_sum"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "main".to_string(),
            "log".to_string(),
            "unwrap_or".to_string(),
            "direction_code".to_string(),
        ],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_enum_match passed!");
}

// ---------------------------------------------------------------------------
// Test 4: While-loop variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify while-loop accumulator results.
///
/// Breakpoint at line 240 (`log(loop_product)`) where Section 4 locals include:
///   loop_sum     = 55   (sum 1..10)
///   fact_val     = 720  (6!)
///   loop_product = 775  (loop_sum + fact_val)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_loop_variables() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("loop_sum".to_string(), 55);
    expected_values.insert("fact_val".to_string(), 720);
    expected_values.insert("loop_product".to_string(), 775);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 240: `log(loop_product);` — loop result locals are in scope.
        breakpoint_line: 240,
        expected_variables: vec!["loop_sum", "fact_val", "loop_product"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "main".to_string(),
            "log".to_string(),
            "sum_to".to_string(),
            "factorial".to_string(),
        ],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_loop_variables passed!");
}

// ---------------------------------------------------------------------------
// Test 5: Nested / chained function calls
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify results of nested function call chains.
///
/// Breakpoint at line 248 (`log(nested_result)`) where Section 5 locals include:
///   transformed   = 22   (transform(5, 3, 7) = 5*3 + 7)
///   nested_result = 364  (double(22) + multiply(10, 32) = 44 + 320)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_nested_calls() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("transformed".to_string(), 22);
    expected_values.insert("nested_result".to_string(), 364);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 248: `log(nested_result);` — nested-call locals are in scope.
        breakpoint_line: 248,
        expected_variables: vec!["transformed", "nested_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "main".to_string(),
            "log".to_string(),
            "transform".to_string(),
            "double".to_string(),
            "multiply".to_string(),
        ],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_nested_calls passed!");
}

// ---------------------------------------------------------------------------
// Test 6: Array and tuple operations
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify array indexing and tuple element access.
///
/// Breakpoint at line 260 (`log(tup_sum)`) where Section 6 locals include:
///   arr_first = 10   (arr[0])
///   arr_last  = 50   (arr[4])
///   arr_sum   = 60   (arr_first + arr_last)
///   tup_first = 42   (tup.0)
///   tup_third = 99   (tup.2)
///   tup_sum   = 141  (tup_first + tup_third)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_array_tuple() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("arr_first".to_string(), 10);
    expected_values.insert("arr_last".to_string(), 50);
    expected_values.insert("arr_sum".to_string(), 60);
    expected_values.insert("tup_first".to_string(), 42);
    expected_values.insert("tup_third".to_string(), 99);
    expected_values.insert("tup_sum".to_string(), 141);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 260: `log(tup_sum);` — array and tuple locals are in scope.
        breakpoint_line: 260,
        expected_variables: vec!["arr_first", "arr_last", "arr_sum", "tup_first", "tup_third", "tup_sum"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["main".to_string(), "log".to_string()],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_array_tuple passed!");
}

// ---------------------------------------------------------------------------
// Test 7: Fibonacci computation
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify iterative Fibonacci results.
///
/// Breakpoint at line 266 (`log(fib_sum)`) where Section 7 locals include:
///   fib_10  = 55    (10th Fibonacci number)
///   fib_20  = 6765  (20th Fibonacci number)
///   fib_sum = 6820  (fib_10 + fib_20)
#[test]
#[ignore = "requires fuel-recorder; run via: just test-sway-flow"]
fn sway_flow_dap_fibonacci() {
    let (db_backend, recording, breakpoint_source) = setup_sway_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("fib_10".to_string(), 55);
    expected_values.insert("fib_20".to_string(), 6765);
    expected_values.insert("fib_sum".to_string(), 6820);

    let config = FlowTestConfig {
        source_file: breakpoint_source.to_str().unwrap().to_string(),
        // Line 266: `log(fib_sum);` — fibonacci locals are in scope.
        breakpoint_line: 266,
        expected_variables: vec!["fib_10", "fib_20", "fib_sum"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["main".to_string(), "log".to_string(), "fibonacci".to_string()],
        expected_values,
    };

    run_dap_test(&db_backend, &recording, &config);
    println!("sway_flow_dap_fibonacci passed!");
}
