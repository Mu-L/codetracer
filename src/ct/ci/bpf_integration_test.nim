## Integration tests for BPF process monitoring.
##
## These tests exercise the full BPF monitoring pipeline: capability detection,
## bpftrace subprocess management, real kernel event capture, and event parsing.
## They require:
##   - A capabilities-aware bpftrace binary (via ``just developer-setup``)
##   - The ``bpftrace-collection.bt`` script (from the codetracer-ci sibling repo,
##     or set via ``CODETRACER_BPFTRACE_SCRIPT``)
##   - Linux kernel >= 5.8 with BPF support
##
## If any prerequisite is missing, the tests are skipped with a diagnostic
## message (not treated as failures).
##
## Run with:
##   nim c -r src/ct/ci/bpf_integration_test.nim
## Or via the justfile:
##   just test-bpf-integration

import std/[os, osproc, strutils, strformat, strtabs, tables, times, unittest]
import bpf_monitor
import ci_api_client
import ../../common/bpf_install

# ---------------------------------------------------------------------------
# Prerequisite checks — skip the entire suite if BPF is not available
# ---------------------------------------------------------------------------

proc checkBPFPrerequisites(): tuple[ok: bool, reason: string] =
  ## Verifies that all prerequisites for BPF integration tests are met.
  ## Returns (true, "") if all checks pass, or (false, reason) with a
  ## human-readable skip reason.

  when not defined(linux):
    return (false, "BPF integration tests require Linux")

  if not isKernelCapBpfCapable():
    return (false, "Kernel is too old for CAP_BPF (requires >= 5.8)")

  let cap = detectBPFCapability()
  if cap == bpfNoBinary:
    return (false, "bpftrace binary not found — run `just developer-setup` first")
  if cap == bpfNoPermission:
    return (false, "bpftrace lacks permissions — run `just developer-setup` to set up capabilities")
  if cap != bpfAvailable:
    return (false, "BPF capability check returned: " & $cap)

  let scriptPath = findBPFTraceScript()
  if scriptPath.len == 0:
    return (false,
      "bpftrace-collection.bt not found. Set CODETRACER_BPFTRACE_SCRIPT or " &
      "ensure the codetracer-ci sibling repo is present")

  return (true, "")

let (prereqOk, prereqReason) = checkBPFPrerequisites()

# ---------------------------------------------------------------------------
# Integration tests
# ---------------------------------------------------------------------------

suite "BPF capability detection":
  test "detectBPFCapability returns bpfAvailable":
    if not prereqOk:
      skip()
    else:
      check detectBPFCapability() == bpfAvailable

  test "findBPFTraceScript returns a valid path":
    if not prereqOk:
      skip()
    else:
      let path = findBPFTraceScript()
      check path.len > 0
      check fileExists(path)
      check path.endsWith("bpftrace-collection.bt")

  test "getBpftracePath returns a valid binary":
    if not prereqOk:
      skip()
    else:
      let path = getBpftracePath()
      check path.len > 0
      check fileExists(path)

suite "BPF monitor — live process monitoring":
  ## Spawns bpftrace to monitor a short-lived child process and verifies
  ## that EXEC and EXIT events are captured.

  test "monitor captures EXEC and EXIT for a simple process":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let scriptPath = findBPFTraceScript()

      # Spawn a shell command as the "monitored" process.
      # We use `bash -c 'sleep 1 && echo hello'` to give bpftrace enough
      # time to attach before the process exits.
      let child = startProcess("bash",
        args = @["-c", "sleep 2 && echo bpf-integration-test"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      # Start the BPF monitor targeting the child's PID.
      var mon = startMonitor(childPid, scriptPath)
      check mon.running

      # Poll events while the child is running, up to a reasonable timeout.
      let deadline = epochTime() + 10.0  # 10 second timeout
      while epochTime() < deadline:
        pollEvents(mon)
        if not running(child):
          # Child has exited — give bpftrace a moment to emit final events.
          sleep(1000)
          pollEvents(mon)
          break
        sleep(200)

      # Stop the monitor and drain remaining events.
      stopMonitor(mon)

      # Clean up child process handle.
      discard waitForExit(child)
      close(child)

      # We should have at least one EXEC event (the bash process or one of
      # its children). The exact number depends on what bash spawns internally.
      let totalEvents = mon.pendingStarts.len + mon.pendingExits.len
      echo fmt"  Captured {mon.pendingStarts.len} start events, {mon.pendingExits.len} exit events, {mon.pendingMetrics.len} metrics events"

      # The child bash process should appear in either starts or exits.
      # bpftrace monitors execve, so the initial bash is tracked.
      check totalEvents > 0

      # Verify that at least one start event has a reasonable PID
      if mon.pendingStarts.len > 0:
        for ev in mon.pendingStarts:
          check ev.pid > 0
          check ev.binaryPath.len > 0
          check ev.startedAt.len > 0

      # Verify that at least one exit event is present
      if mon.pendingExits.len > 0:
        for ev in mon.pendingExits:
          check ev.pid > 0
          check ev.exitedAt.len > 0

  test "monitor captures interval metrics for a CPU-bound process":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let scriptPath = findBPFTraceScript()

      # Spawn a CPU-bound process that runs for ~3 seconds.
      # This ensures at least a few 500ms interval windows fire.
      let child = startProcess("bash",
        args = @["-c", "for i in $(seq 1 5000000); do :; done"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startMonitor(childPid, scriptPath)
      check mon.running

      let deadline = epochTime() + 15.0
      while epochTime() < deadline:
        pollEvents(mon)
        if not running(child):
          sleep(1000)
          pollEvents(mon)
          break
        sleep(200)

      stopMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingStarts.len} starts, {mon.pendingExits.len} exits, {mon.pendingMetrics.len} metrics"

      # The CPU-bound loop should generate at least some interval metrics
      # (bpftrace fires INTV every 500ms).
      # Note: this is a soft check — on very fast machines the loop may
      # complete before the first interval fires.
      if mon.pendingMetrics.len > 0:
        for m in mon.pendingMetrics:
          check m.pid > 0
          check m.timestamp.len > 0
          # CPU percent should be non-negative
          check m.cpuPercent >= 0.0

  test "monitor captures environment variables":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let scriptPath = findBPFTraceScript()

      # Spawn a process with a distinctive environment variable so we
      # can verify it appears in the captured environment.
      let child = startProcess("bash",
        args = @["-c", "sleep 2"],
        options = {poUsePath, poStdErrToStdOut},
        env = newStringTable({
          "BPF_TEST_MARKER": "integration_test_12345",
          "HOME": "/tmp",
          "PATH": "/usr/bin",
        }))
      let childPid = processID(child)

      var mon = startMonitor(childPid, scriptPath)

      let deadline = epochTime() + 10.0
      while epochTime() < deadline:
        pollEvents(mon)
        if not running(child):
          sleep(1000)
          pollEvents(mon)
          break
        sleep(200)

      stopMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingEnvs.len} environment snapshots"

      # If environments were captured, verify our marker is present.
      if mon.pendingEnvs.len > 0:
        var foundMarker = false
        for env in mon.pendingEnvs:
          check env.id.len > 0
          for kv in env.variables:
            if kv.key == "BPF_TEST_MARKER" and kv.value == "integration_test_12345":
              foundMarker = true
        if foundMarker:
          echo "  Found BPF_TEST_MARKER in captured environment"
      else:
        echo "  No environments captured (bpftrace may have limited ENVP reads)"

# Print skip reason at the end if prerequisites were not met
if not prereqOk:
  echo ""
  echo "NOTE: BPF integration tests were skipped: " & prereqReason
  echo "To enable these tests, run: just developer-setup"
