//! Headless DAP flow tests for Solana/SBF traces.
//!
//! These tests verify that the DAP server correctly handles Solana traces
//! produced by the codetracer-solana-recorder. They follow the same pattern as
//! `solidity_flow_dap_test.rs`, but target the Solana/SBF recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-solana-recorder` binary (set `CODETRACER_SOLANA_RECORDER_PATH`
//!   or build it in the sibling repo `codetracer-solana-recorder/`)
//!
//! ## Test tiers
//!
//! Each test records a trace of `solana_flow_test.rs`, launches the DAP server,
//! sets a breakpoint at a specific line, and verifies that the expected local
//! variables appear in the flow data with correct values.
//!
//! - `solana_flow_dap_variables` — Basic arithmetic (a, b, sum_val, doubled, final_result)
//! - `solana_flow_dap_struct_variables` — Struct creation and field access
//! - `solana_flow_dap_enum_match` — Enum pattern matching results
//! - `solana_flow_dap_loop_variables` — Loop counters and accumulators
//! - `solana_flow_dap_nested_calls` — Nested function call results
//! - `solana_flow_dap_array_ops` — Array/tuple operation results
//! - `solana_flow_dap_fibonacci` — Recursive and iterative fibonacci results
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run solana_flow_dap`
//! or:
//!   `just test-solana-flow`

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_solana_flow_test, find_solana_recorder, Language, TestRecording};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Returns the path to the db-backend binary (resolved at compile time).
fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Solana flow test source file.
///
/// Discovers the test program from the sibling `codetracer-solana-recorder` repo
/// (canonical location per Test-Program-Layout.md), falling back to the local
/// `test-programs/` directory if the sibling is not available.
fn get_solana_source_path() -> PathBuf {
    find_solana_flow_test().expect(
        "Solana flow test program not found. \
         Check out codetracer-solana-recorder as a sibling repo, or ensure \
         test-programs/solana/solana_flow_test.rs exists locally.",
    )
}

/// Shared setup for all Solana DAP tests.
///
/// 1. Asserts the Solana recorder is available.
/// 2. Asserts the source file exists.
/// 3. Records a trace.
/// 4. Returns (db_backend_path, source_copy_in_trace_dir, recording).
///
/// Panics if any prerequisite is missing or recording fails.
fn setup_solana_trace() -> (PathBuf, PathBuf, TestRecording) {
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

    (db_backend, source_copy, recording)
}

/// Runs a single DAP flow test with the given configuration.
///
/// This helper handles runner creation, verification, and cleanup so that
/// individual tests only need to specify the breakpoint and expectations.
fn run_dap_flow_test(db_backend: &Path, trace_dir: &Path, config: &FlowTestConfig, test_name: &str) {
    let mut runner = FlowTestRunner::new_db_trace(db_backend, trace_dir)
        .unwrap_or_else(|e| panic!("DAP init failed for {}: {}", test_name, e));
    runner
        .run_and_verify(config)
        .unwrap_or_else(|e| panic!("{} failed: {}", test_name, e));
    runner
        .finish()
        .unwrap_or_else(|e| panic!("{} disconnect failed: {}", test_name, e));

    println!("{} passed!", test_name);
}

// ---------------------------------------------------------------------------
// Test: Basic arithmetic variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify basic arithmetic variables inside
/// `process_instruction()` at the `final_result` assignment.
///
/// Expected locals at line 458:
///   a            = 10
///   b            = 32
///   sum_val      = 42  (a + b)
///   doubled      = 84  (sum_val * 2)
///   final_result = 94  (doubled + a)
///
/// Note: Variable names may appear as register names (r1-r5) depending on the
/// Solana trace format. The test checks for whichever representation the
/// recorder produces.
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_variables() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("a".to_string(), 10);
    expected_values.insert("b".to_string(), 32);
    expected_values.insert("sum_val".to_string(), 42);
    expected_values.insert("doubled".to_string(), 84);
    expected_values.insert("final_result".to_string(), 94);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 458: `let final_result: u64 = doubled + a;`
        breakpoint_line: 458,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec!["process_instruction".to_string()],
        expected_values,
    };

    run_dap_flow_test(&db_backend, &recording.trace_dir, &config, "solana_flow_dap_variables");
}

// ---------------------------------------------------------------------------
// Test: Struct variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify struct-related variables after creating an
/// AccountInfo and processing it.
///
/// Expected locals at line 465 (`struct_check` assignment):
///   account_total = 1520  (1000 + 42*10 + 100)
///   struct_check  = 1520
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_struct_variables() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("account_total".to_string(), 1520);
    expected_values.insert("struct_check".to_string(), 1520);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 465: `let struct_check: u64 = account_total;`
        breakpoint_line: 465,
        expected_variables: vec!["account_total", "struct_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "create_account".to_string(),
            "process_account".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(
        &db_backend,
        &recording.trace_dir,
        &config,
        "solana_flow_dap_struct_variables",
    );
}

// ---------------------------------------------------------------------------
// Test: Enum pattern matching
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify enum/match-related variables after executing a
/// Transfer instruction.
///
/// Expected locals at line 473 (`enum_check` assignment):
///   transfer_value = 490  (1000 - 500 - 10)
///   enum_check     = 490
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_enum_match() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("transfer_value".to_string(), 490);
    expected_values.insert("enum_check".to_string(), 490);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 473: `let enum_check: u64 = transfer_value;`
        breakpoint_line: 473,
        expected_variables: vec!["transfer_value", "enum_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "execute_instruction".to_string(),
            "unwrap_result".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(&db_backend, &recording.trace_dir, &config, "solana_flow_dap_enum_match");
}

// ---------------------------------------------------------------------------
// Test: Loop variables
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify loop-related variables after while, for, and
/// loop/break constructs.
///
/// Expected locals at line 498 (`loop_check` assignment):
///   while_sum   = 210
///   for_sum     = 210
///   first_above = 40
///   loop_check  = 460  (210 + 210 + 40)
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_loop_variables() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("while_sum".to_string(), 210);
    expected_values.insert("for_sum".to_string(), 210);
    expected_values.insert("first_above".to_string(), 40);
    expected_values.insert("loop_check".to_string(), 460);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 498: `let loop_check: u64 = while_sum + for_sum + first_above;`
        breakpoint_line: 498,
        expected_variables: vec!["while_sum", "for_sum", "first_above", "loop_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "sum_while".to_string(),
            "sum_for".to_string(),
            "find_first_above".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(
        &db_backend,
        &recording.trace_dir,
        &config,
        "solana_flow_dap_loop_variables",
    );
}

// ---------------------------------------------------------------------------
// Test: Nested function calls
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify variables from nested function call chains.
///
/// Expected locals at line 514 (`nested_check` assignment):
///   nested_val   = 70   (nested_computation(10, 3, 5))
///   deep_val     = 120  (deeply_nested(5, 10))
///   nested_check = 190  (70 + 120)
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_nested_calls() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("nested_val".to_string(), 70);
    expected_values.insert("deep_val".to_string(), 120);
    expected_values.insert("nested_check".to_string(), 190);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 514: `let nested_check: u64 = nested_val + deep_val;`
        breakpoint_line: 514,
        expected_variables: vec!["nested_val", "deep_val", "nested_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "nested_computation".to_string(),
            "deeply_nested".to_string(),
            "add_u64".to_string(),
            "mul_u64".to_string(),
            "saturating_sub".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(
        &db_backend,
        &recording.trace_dir,
        &config,
        "solana_flow_dap_nested_calls",
    );
}

// ---------------------------------------------------------------------------
// Test: Array and tuple operations
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify variables from array and tuple operations.
///
/// Expected locals at line 523 (`array_check` assignment):
///   arr_min      = 2
///   arr_max      = 80
///   arr_sum      = 117
///   tuple_result = 1800
///   array_check  = 1999  (2 + 80 + 117 + 1800)
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_array_ops() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("arr_min".to_string(), 2);
    expected_values.insert("arr_max".to_string(), 80);
    expected_values.insert("arr_sum".to_string(), 117);
    expected_values.insert("tuple_result".to_string(), 1800);
    expected_values.insert("array_check".to_string(), 1999);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 523: `let array_check: u64 = arr_min + arr_max + arr_sum + tuple_result;`
        breakpoint_line: 523,
        expected_variables: vec!["arr_min", "arr_max", "arr_sum", "tuple_result", "array_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "array_operations".to_string(),
            "tuple_operations".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(&db_backend, &recording.trace_dir, &config, "solana_flow_dap_array_ops");
}

// ---------------------------------------------------------------------------
// Test: Fibonacci
// ---------------------------------------------------------------------------

/// Tier 2 (DAP flow): Verify fibonacci computation results (both recursive
/// and iterative).
///
/// Expected locals at line 530 (`fib_check` assignment):
///   fib_recursive  = 55  (fibonacci(10))
///   fib_iterative  = 55  (fibonacci_iterative(10))
///   fib_check      = 110 (55 + 55)
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_flow_dap_fibonacci() {
    let (db_backend, source_copy, recording) = setup_solana_trace();

    let mut expected_values = HashMap::new();
    expected_values.insert("fib_recursive".to_string(), 55);
    expected_values.insert("fib_iterative".to_string(), 55);
    expected_values.insert("fib_check".to_string(), 110);

    let config = FlowTestConfig {
        source_file: source_copy.to_str().unwrap().to_string(),
        // Line 530: `let fib_check: u64 = fib_recursive + fib_iterative;`
        breakpoint_line: 530,
        expected_variables: vec!["fib_recursive", "fib_iterative", "fib_check"]
            .into_iter()
            .map(String::from)
            .collect(),
        excluded_identifiers: vec![
            "process_instruction".to_string(),
            "fibonacci".to_string(),
            "fibonacci_iterative".to_string(),
        ],
        expected_values,
    };

    run_dap_flow_test(&db_backend, &recording.trace_dir, &config, "solana_flow_dap_fibonacci");
}
