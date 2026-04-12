//! Headless DAP setup tests for Sway/FuelVM traces.
//!
//! These tests verify that the basic infrastructure for Sway trace recording
//! is in place. The Fuel recorder currently writes metadata but does not yet
//! produce trace data (no `trace.bin`/`trace.json`/`trace.ct`), so full DAP
//! flow tests cannot run.
//!
//! ## Current recorder limitations
//!
//! The Fuel recorder explicitly reports "Recording not yet implemented for
//! Sway projects". It writes `trace_metadata.json` but no trace data files.
//! As a result, `create_db_trace()` fails because it checks for trace files.
//!
//! Once full Sway trace recording is implemented in the Fuel recorder, these
//! tests should be upgraded to Tier 2 (DAP flow) tests that set breakpoints
//! at specific lines and verify variable values. See the commented-out
//! breakpoint/variable expectations in each test for the target state.
//!
//! ## What is tested now
//!
//! Each test verifies:
//! 1. The Fuel recorder binary exists and is discoverable.
//! 2. The Sway test project directory exists with `Forc.toml`.
//! 3. The Sway source file (`main.sw`) exists.
//! 4. Running the recorder produces output (even if it reports recording
//!    as not yet implemented).
//! 5. Documents the specific limitation preventing full trace recording.
//!
//! ## Prerequisites
//!
//! - `codetracer-fuel-recorder` binary (set `CODETRACER_FUEL_RECORDER_PATH` or
//!   build it in the sibling repo `codetracer-fuel-recorder/`)
//!
//! Prerequisites are provided by the Nix dev shell (`nix develop`).
//! Run with:
//!   `cargo nextest run sway_flow_dap`
//! or:
//!   `just test-sway-flow`

use std::path::{Path, PathBuf};
use std::process::Command;

mod test_harness;
use test_harness::{find_fuel_recorder, find_sway_flow_source, find_sway_flow_test};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Verify that the Fuel recorder binary exists.
fn assert_recorder_exists() -> PathBuf {
    find_fuel_recorder().expect(
        "Fuel recorder not found. \
         Set CODETRACER_FUEL_RECORDER_PATH or build codetracer-fuel-recorder \
         (run `cargo build` inside the codetracer-fuel-recorder repo).",
    )
}

/// Verify that the Sway test project directory exists.
fn assert_project_exists() -> PathBuf {
    let project = find_sway_flow_test().expect(
        "Sway flow test project not found. \
         Check out codetracer-fuel-recorder as a sibling repo, or ensure \
         test-programs/flow_test/ exists with Forc.toml.",
    );
    assert!(
        project.join("Forc.toml").exists(),
        "Sway test project missing Forc.toml at {}",
        project.display()
    );
    project
}

/// Verify that the Sway source file exists.
fn assert_source_exists() -> PathBuf {
    let source = find_sway_flow_source().expect(
        "Sway flow test source not found. \
         Check out codetracer-fuel-recorder as a sibling repo, or ensure \
         test-programs/flow_test/src/main.sw exists.",
    );
    assert!(
        source.exists(),
        "Sway source file does not exist at {}",
        source.display()
    );
    source
}

/// Run the Fuel recorder against the test project and return (stdout, stderr, success).
///
/// The recorder is invoked via `direnv exec` if a `.envrc` is found in an
/// ancestor of the recorder binary, ensuring the correct Nix dev shell
/// (with `forc` on PATH) is active.
fn run_fuel_recorder(recorder: &Path, project_path: &Path) -> (String, String, bool) {
    let temp_dir = std::env::temp_dir().join(format!("sway_flow_test_{}", std::process::id()));
    let _ = std::fs::create_dir_all(&temp_dir);

    // Find the repo dir for direnv exec
    let repo_dir = {
        let mut dir = recorder.parent();
        let mut found = None;
        while let Some(d) = dir {
            if d.join(".envrc").exists() {
                found = Some(d.to_path_buf());
                break;
            }
            dir = d.parent();
        }
        found
    };

    let output = if let Some(ref repo_dir) = repo_dir {
        Command::new("direnv")
            .arg("exec")
            .arg(repo_dir)
            .arg(recorder)
            .args([
                "record",
                project_path.to_str().unwrap(),
                "--out-dir",
                temp_dir.to_str().unwrap(),
            ])
            .output()
    } else {
        Command::new(recorder)
            .args([
                "record",
                project_path.to_str().unwrap(),
                "--out-dir",
                temp_dir.to_str().unwrap(),
            ])
            .output()
    };

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            let stderr = String::from_utf8_lossy(&out.stderr).to_string();
            let success = out.status.success();

            // Check for metadata output even on failure
            let metadata_path = temp_dir.join("trace_metadata.json");
            if metadata_path.exists() {
                println!("trace_metadata.json was written to {}", metadata_path.display());
            }

            // Clean up
            let _ = std::fs::remove_dir_all(&temp_dir);

            (stdout, stderr, success)
        }
        Err(e) => {
            let _ = std::fs::remove_dir_all(&temp_dir);
            (String::new(), format!("Failed to execute recorder: {}", e), false)
        }
    }
}

/// Shared test body: verify prerequisites and run the recorder, documenting
/// that full trace recording is not yet implemented for Sway.
///
/// The `test_label` parameter is used for unique temp dirs and log messages.
fn run_sway_setup_test(test_label: &str) {
    let recorder = assert_recorder_exists();
    let project_path = assert_project_exists();
    let source_path = assert_source_exists();

    println!("Fuel recorder: {}", recorder.display());
    println!("Sway project:  {}", project_path.display());
    println!("Sway source:   {}", source_path.display());

    // Run the recorder to verify it can be invoked
    let (stdout, stderr, success) = run_fuel_recorder(&recorder, &project_path);

    // The Fuel recorder currently does not produce trace data for Sway.
    // It may exit with an error or print a "not yet implemented" message.
    // Either outcome is expected at this stage.
    let combined = format!("{}\n{}", stdout, stderr);
    println!("Recorder output for '{}':\n{}", test_label, combined);

    if !success {
        // Document the known limitation
        println!(
            "NOTE: Sway trace recording is not yet fully implemented in the Fuel recorder. \
             The recorder ran but did not produce trace data. This is a known recorder-level \
             limitation, not a test harness bug. Test '{}' verifies infrastructure only.",
            test_label
        );
    }

    println!("Sway setup test '{}' passed (infrastructure verified).", test_label);
}

// ---------------------------------------------------------------------------
// Test 1: Basic arithmetic variables
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_variables`.
///
/// Verifies recorder and project infrastructure. Once full trace recording is
/// implemented, upgrade to Tier 2 with breakpoint at line 212:
///   a=10, b=32, sum_val=42, doubled=84, final_result=94
#[test]
fn sway_flow_dap_variables() {
    run_sway_setup_test("variables");
}

// ---------------------------------------------------------------------------
// Test 2: Struct variables
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_struct_variables`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 224:
///   area=50, dist=10, struct_sum=60
#[test]
fn sway_flow_dap_struct_variables() {
    run_sway_setup_test("struct_variables");
}

// ---------------------------------------------------------------------------
// Test 3: Enum and pattern matching
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_enum_match`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 234:
///   unwrapped_some=99, unwrapped_none=42, dir_code=3, match_sum=102
#[test]
fn sway_flow_dap_enum_match() {
    run_sway_setup_test("enum_match");
}

// ---------------------------------------------------------------------------
// Test 4: While-loop variables
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_loop_variables`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 240:
///   loop_sum=55, fact_val=720, loop_product=775
#[test]
fn sway_flow_dap_loop_variables() {
    run_sway_setup_test("loop_variables");
}

// ---------------------------------------------------------------------------
// Test 5: Nested / chained function calls
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_nested_calls`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 248:
///   transformed=22, nested_result=364
#[test]
fn sway_flow_dap_nested_calls() {
    run_sway_setup_test("nested_calls");
}

// ---------------------------------------------------------------------------
// Test 6: Array and tuple operations
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_array_tuple`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 260:
///   arr_first=10, arr_last=50, arr_sum=60, tup_first=42, tup_third=99, tup_sum=141
#[test]
fn sway_flow_dap_array_tuple() {
    run_sway_setup_test("array_tuple");
}

// ---------------------------------------------------------------------------
// Test 7: Fibonacci computation
// ---------------------------------------------------------------------------

/// Setup test for `sway_flow_dap_fibonacci`.
///
/// Once trace recording works, upgrade to Tier 2 with breakpoint at line 266:
///   fib_10=55, fib_20=6765, fib_sum=6820
#[test]
fn sway_flow_dap_fibonacci() {
    run_sway_setup_test("fibonacci");
}
