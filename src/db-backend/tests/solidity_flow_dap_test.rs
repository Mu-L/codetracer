//! Headless DAP flow test for Solidity/EVM traces.
//!
//! This test verifies that the DAP server correctly handles Solidity traces
//! produced by the codetracer-evm-recorder. It follows the same pattern as
//! `python_flow_dap_test.rs` (live recording), but targets the Solidity/EVM
//! recording pipeline.
//!
//! ## Prerequisites
//!
//! - `codetracer-evm-recorder` binary (set `CODETRACER_EVM_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-evm-recorder/`)
//! - `solc` (Solidity compiler) on PATH or set `SOLC_PATH`
//! - `anvil` (Foundry) on PATH for a local EVM node
//!
//! ## Test tiers
//!
//! - `solidity_flow_dap_variables` (Tier 2): Records a trace of
//!   `solidity_flow_test.sol`, launches the DAP server, sets a breakpoint inside
//!   `run()`, and verifies the expected local variables appear in flow data.
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run solidity_flow_dap`
//! or:
//!   `just test-solidity-flow`

use std::collections::HashMap;
use std::path::PathBuf;

use ct_dap_client::test_support::{FlowTestConfig, FlowTestRunner};

mod test_harness;
use test_harness::{find_evm_recorder, Language, TestRecording};

fn find_db_backend() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_db-backend"))
}

/// Returns the path to the Solidity flow test source file.
fn get_solidity_source_path() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir.join("test-programs/solidity/solidity_flow_test.sol")
}

/// Check if `solc` (Solidity compiler) is available on PATH or via `SOLC_PATH`.
fn is_solc_available() -> bool {
    let cmd = std::env::var("SOLC_PATH").unwrap_or_else(|_| "solc".to_string());
    std::process::Command::new(&cmd)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Check if `anvil` (Foundry local EVM node) is available on PATH.
fn is_anvil_available() -> bool {
    std::process::Command::new("anvil")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Tier 2 (DAP flow): Record a Solidity trace and verify that the DAP server can
/// set a breakpoint inside `run()`, continue to it, and extract the expected local
/// variables from the flow data.
///
/// Expected local variables inside `run()` at line 39 (`final_result` assignment):
///   a           = 10
///   b           = 32
///   sum_val     = 42
///   doubled     = 84
///   final_result = 94
///
/// Prerequisites: `codetracer-evm-recorder`, `solc`, and `anvil`.
/// These are provided by the Nix dev shell (`nix develop`).
#[test]
#[ignore = "requires evm-recorder dev shell (solc, anvil); run via: just test-solidity-flow"]
fn solidity_flow_dap_variables() {
    // --- Prerequisite checks ---
    assert!(
        find_evm_recorder().is_some(),
        "EVM recorder not found. \
         Set CODETRACER_EVM_RECORDER_PATH or build codetracer-evm-recorder \
         (run `cargo build` inside the codetracer-evm-recorder repo)."
    );

    assert!(
        is_solc_available(),
        "solc (Solidity compiler) not found. Install solc or set SOLC_PATH."
    );

    assert!(
        is_anvil_available(),
        "anvil not found. Install Foundry (https://getfoundry.sh) or add it to PATH."
    );

    let db_backend = find_db_backend();
    let source_path = get_solidity_source_path();

    assert!(
        source_path.exists(),
        "Solidity test program not found at {}",
        source_path.display()
    );

    // Record the Solidity trace via the EVM recorder CLI.
    let recording = TestRecording::create_db_trace(&source_path, Language::Solidity, "solidity-0.8")
        .expect("Solidity recording failed — check that solc, anvil, and evm-recorder are available");

    println!("Trace recorded to: {}", recording.trace_dir.display());

    // The EVM recorder copies the source file into trace_dir and stores just
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
        // Line 39: `uint256 final_result = doubled + 10;` — all 5 locals are in scope here.
        breakpoint_line: 39,
        expected_variables: vec!["a", "b", "sum_val", "doubled", "final_result"]
            .into_iter()
            .map(String::from)
            .collect(),
        // `storedResult` and `Computed` should not appear as local variables
        excluded_identifiers: vec!["storedResult".to_string(), "Computed".to_string()],
        expected_values,
    };

    let mut runner =
        FlowTestRunner::new_db_trace(&db_backend, &recording.trace_dir).expect("DAP init failed for Solidity trace");
    runner.run_and_verify(&config).expect("Solidity flow DAP test failed");
    runner.finish().expect("disconnect failed");

    println!("Solidity DAP flow test passed!");
}
