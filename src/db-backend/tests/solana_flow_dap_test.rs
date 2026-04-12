//! Headless DAP tests for Solana/SBF traces.
//!
//! The Solana recorder requires TWO inputs:
//!   1. A compiled SBF ELF binary (for DWARF debug info / source mapping)
//!   2. A register trace file (`--regs`) from an SBF VM execution
//!
//! Without `--regs`, the recorder only writes placeholder metadata.
//! Building SBF ELFs requires `cargo-build-sbf` which depends on the
//! Solana SDK toolchain.
//!
//! These tests verify that the recorder infrastructure is available and
//! that the test program exists. Full trace recording requires completing
//! the SBF execution pipeline in the recorder.

mod test_harness;
use test_harness::{find_solana_flow_test, find_solana_recorder};

/// Verify the Solana recorder binary is available and the test program exists.
///
/// This test asserts that the infrastructure is correctly set up. It does NOT
/// produce a skip — if the recorder or test program is missing, the test FAILS
/// with a descriptive message about what to fix.
#[test]
#[ignore = "requires solana-recorder; run via: just test-solana-flow"]
fn solana_recorder_infrastructure() {
    let recorder = find_solana_recorder();
    assert!(
        recorder.is_some(),
        "Solana recorder not found. \
         Build it: cd ../codetracer-solana-recorder && cargo build --release"
    );

    let source = find_solana_flow_test();
    assert!(
        source.is_some(),
        "Solana test program not found. \
         Expected at codetracer-solana-recorder/test-programs/solana/solana_flow_test.rs"
    );

    let recorder_path = recorder.unwrap();
    let source_path = source.unwrap();
    assert!(recorder_path.exists());
    assert!(source_path.exists());

    // Verify the recorder responds to --version
    let output = std::process::Command::new(&recorder_path)
        .arg("--version")
        .output()
        .expect("failed to run solana recorder --version");
    assert!(
        output.status.success(),
        "Solana recorder --version failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    println!(
        "Solana recorder: {} ({})",
        recorder_path.display(),
        String::from_utf8_lossy(&output.stdout).trim()
    );
    println!("Test program: {}", source_path.display());
    println!("NOTE: Full trace recording requires --regs (SBF register trace file).");
    println!("      The SBF execution pipeline is not yet integrated into the recorder.");
}
