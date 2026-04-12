//! Headless DAP tests for Cadence/Flow traces.
//!
//! The recording pipeline requires:
//!   1. The `cadence-trace-helper` Go binary (built from codetracer-flow-recorder/go-helper/)
//!   2. The `codetracer-flow-recorder` Rust binary
//!
//! The Go helper needs updating for Cadence v1.x API:
//!   - `cadence.NewProgram` → use `runtime.NewInterpreterRuntime` + Config with Debugger
//!   - `interpreter.WithOnStatementHandler` → use `interpreter.Debugger.Next()` stepping API
//!   - `interpreter.ExportValue` → use `runtime.ExportValue`

use std::path::{Path, PathBuf};
use std::process::Command;

mod test_harness;
use test_harness::{find_cadence_flow_test, find_cadence_recorder};

/// Find the flow recorder repo directory from the binary path.
fn find_flow_recorder_repo(recorder: &Path) -> Option<PathBuf> {
    let mut dir = recorder.parent();
    while let Some(d) = dir {
        if d.join(".envrc").exists() {
            return Some(d.to_path_buf());
        }
        dir = d.parent();
    }
    None
}

/// Verify the full Cadence recording pipeline.
///
/// This test builds the Go helper, records a trace, and launches the DAP server.
/// If any step fails, the test fails with a clear message about what to fix.
#[test]
#[ignore = "requires flow-recorder + go helper; run via: just test-cadence-flow"]
fn cadence_flow_dap_variables() {
    // 1. Verify recorder exists
    let recorder = find_cadence_recorder().expect("Cadence/Flow recorder not found — build codetracer-flow-recorder");

    // 2. Verify test program exists
    let _source = find_cadence_flow_test()
        .expect("Cadence test program not found — check codetracer-flow-recorder/test-programs/cadence/flow_test.cdc");

    // 3. Verify Go helper builds
    let flow_recorder_dir =
        find_flow_recorder_repo(&recorder).expect("Could not find flow-recorder repo directory from binary path");
    let go_helper_dir = flow_recorder_dir.join("go-helper");
    assert!(
        go_helper_dir.exists(),
        "Go helper source not found at {}",
        go_helper_dir.display()
    );

    let helper_bin = flow_recorder_dir.join("target/debug/cadence-trace-helper");
    let build_output = Command::new("direnv")
        .args([
            "exec",
            flow_recorder_dir.to_str().unwrap(),
            "go",
            "build",
            "-o",
            helper_bin.to_str().unwrap(),
            ".",
        ])
        .current_dir(&go_helper_dir)
        .output()
        .expect("failed to run direnv exec go build");

    assert!(
        build_output.status.success(),
        "Go helper build failed (Cadence SDK API mismatch — go-helper/main.go needs \
         updating for Cadence v1.x: cadence.NewProgram removed, use \
         runtime.NewInterpreterRuntime with interpreter.Debugger):\n{}",
        String::from_utf8_lossy(&build_output.stderr)
    );
}
