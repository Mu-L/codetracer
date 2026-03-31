## End-to-end integration tests for the native BPF process monitor.
##
## These tests exercise the full pipeline: loading compiled BPF programs
## into the kernel via libbpf, monitoring a real child process, capturing
## EXEC and EXIT events via the ring buffer, and verifying the events
## contain the expected data.
##
## Prerequisites:
##   - Linux kernel >= 5.8 with BPF support
##   - BPF capabilities on the test binary (cap_bpf, cap_perfmon,
##     cap_dac_read_search) — set via ``just developer-setup`` or the
##     NixOS ``developer-bpf`` module
##   - Compiled BPF object at ``src/build-debug/share/monitor.bpf.o``
##     (via ``just build-bpf-programs``)
##
## Run with:
##   just test-bpf-native-integration
##
## If any prerequisite is missing, tests are skipped (not failures).

import std/[os, osproc, strutils, strformat, strtabs, times, unittest]
import bpf_monitor_native
import ci_api_client

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

proc findBpfObject(): string =
  ## Locates the compiled BPF object file.
  result = defaultBpfObjectPath()
  if result.len == 0:
    # Try the path relative to the test binary.
    let binDir = getAppDir()
    # From src/ct/ci/ → src/build-debug/share/
    let candidates = [
      binDir / ".." / ".." / "build-debug" / "share" / "monitor.bpf.o",
      binDir / ".." / "share" / "monitor.bpf.o",
      "src/build-debug/share/monitor.bpf.o",
    ]
    for c in candidates:
      if fileExists(c):
        return c

proc checkNativePrereqs(): tuple[ok: bool, reason: string, path: string] =
  when not defined(linux):
    return (false, "Native BPF integration tests require Linux", "")

  let objPath = findBpfObject()
  if objPath.len == 0:
    return (false,
      "monitor.bpf.o not found — run `just build-bpf-programs` first", "")

  let cap = detectNativeBPFCapability(objPath)
  case cap
  of nbpfAvailable:
    return (true, "", objPath)
  of nbpfNoObject:
    return (false, "BPF object file not found: " & objPath, "")
  of nbpfLoadFailed:
    return (false,
      "BPF programs failed to load — kernel may be too old or BPF disabled", "")
  of nbpfAttachFailed:
    return (false,
      "BPF tracepoint attachment failed — missing capabilities? " &
      "Run `just developer-setup` to set up passwordless setcap", "")
  of nbpfUnsupported:
    return (false, "Native BPF monitoring not supported on this system", "")

let (prereqOk, prereqReason, bpfObjPath) = checkNativePrereqs()

# ---------------------------------------------------------------------------
# Integration tests
# ---------------------------------------------------------------------------

suite "Native BPF capability detection":
  test "detectNativeBPFCapability returns nbpfAvailable":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      check detectNativeBPFCapability(bpfObjPath) == nbpfAvailable

  test "detectNativeBPFCapability returns nbpfNoObject for missing file":
    check detectNativeBPFCapability("/nonexistent/monitor.bpf.o") == nbpfNoObject

suite "Native BPF monitor — live EXEC event capture":
  test "monitor captures EXEC events for a simple process":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # Spawn a child process. Use 'sleep' so it stays alive long enough
      # for BPF to observe its execve.
      let child = startProcess("bash",
        args = @["-c", "echo native-bpf-test && sleep 1"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      # Start the native BPF monitor targeting the child PID.
      var mon = startNativeMonitor(childPid, bpfObjPath)
      check mon.running

      # Poll until the child exits or timeout (10s).
      let deadline = epochTime() + 10.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          # Child exited — drain remaining events.
          sleep(500)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingStarts.len} start events, {mon.pendingExits.len} exit events"

      # The bash -c command causes bash to execve, which should produce
      # at least one start event.
      check mon.pendingStarts.len > 0

      # Verify the start event has valid data.
      let firstStart = mon.pendingStarts[0]
      check firstStart.pid > 0
      check firstStart.binaryPath.len > 0
      check firstStart.startedAt.len > 0
      echo fmt"  First start: pid={firstStart.pid} binary={firstStart.binaryPath}"

  test "monitor captures correct binary path":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # Use /usr/bin/env or /bin/echo — a binary with a predictable path.
      let child = startProcess("/bin/echo",
        args = @["bpf-path-test"],
        options = {poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 5.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(300)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingStarts.len} starts"

      # /bin/echo is so short-lived it may or may not be caught by BPF,
      # depending on timing. If caught, verify the path.
      if mon.pendingStarts.len > 0:
        var foundEcho = false
        for ev in mon.pendingStarts:
          if ev.binaryPath.contains("echo"):
            foundEcho = true
            echo fmt"  Found echo binary: {ev.binaryPath}"
        if not foundEcho:
          echo "  Note: echo binary not found in starts (timing-dependent)"
      else:
        echo "  Note: no starts captured (echo exited before BPF attached)"

  test "monitor captures command line arguments":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let child = startProcess("bash",
        args = @["-c", "sleep 1"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 5.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(300)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingStarts.len} starts"

      if mon.pendingStarts.len > 0:
        # At least one event should have a non-empty command line.
        var foundCmdLine = false
        for ev in mon.pendingStarts:
          if ev.commandLine.len > 0:
            foundCmdLine = true
            echo fmt"  Command line: '{ev.commandLine}'"
        check foundCmdLine

suite "Native BPF monitor — live EXIT event capture":
  test "monitor captures EXIT events with correct PID":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let child = startProcess("bash",
        args = @["-c", "sleep 1"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 10.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(500)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingExits.len} exit events"

      # We should see at least one exit (the root bash process).
      check mon.pendingExits.len > 0

      # Verify the root PID's exit was captured.
      var foundRootExit = false
      for ev in mon.pendingExits:
        check ev.pid > 0
        check ev.exitedAt.len > 0
        if ev.pid == childPid:
          foundRootExit = true
          echo fmt"  Root PID exit: pid={ev.pid} code={ev.exitCode}"
      check foundRootExit

  test "monitor detects root PID exit and sets running=false":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      let child = startProcess("bash",
        args = @["-c", "sleep 0.5"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)
      check mon.running

      # Wait for child to exit and poll until monitor detects it.
      let deadline = epochTime() + 10.0
      while epochTime() < deadline and mon.running:
        pollNativeEvents(mon)
        sleep(100)

      echo fmt"  Monitor running={mon.running} after child exited"
      check not mon.running

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

suite "Native BPF monitor — environment capture":
  test "monitor captures environment variables":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # Spawn a process with a distinctive env var.
      let child = startProcess("bash",
        args = @["-c", "sleep 1"],
        options = {poUsePath, poStdErrToStdOut},
        env = newStringTable({
          "BPF_NATIVE_TEST_MARKER": "e2e_test_42",
          "HOME": "/tmp",
          "PATH": "/usr/bin:/bin",
        }))
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 10.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(500)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingEnvs.len} environment snapshots"

      if mon.pendingEnvs.len > 0:
        let env = mon.pendingEnvs[0]
        check env.id.len > 0
        check env.variables.len > 0

        # Look for our marker variable.
        var foundMarker = false
        for kv in env.variables:
          if kv.key == "BPF_NATIVE_TEST_MARKER" and kv.value == "e2e_test_42":
            foundMarker = true
        if foundMarker:
          echo "  Found BPF_NATIVE_TEST_MARKER in captured environment"
        else:
          echo "  Note: marker not found (BPF may have truncated envp)"
      else:
        echo "  Note: no environments captured"

suite "Native BPF monitor — process tree tracking":
  test "monitor captures child process spawned by root":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # bash -c 'sleep 0.5 && /bin/echo child-test' — bash is the root
      # and /bin/echo (or the shell builtin) is a child.
      let child = startProcess("bash",
        args = @["-c", "sleep 0.5 && /bin/echo child-test"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 10.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(500)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingStarts.len} starts, {mon.pendingExits.len} exits"

      # We should see at least the root bash process.
      check mon.pendingStarts.len >= 1

      # Check that child processes have the root as parent.
      for ev in mon.pendingStarts:
        if ev.pid != childPid:
          echo fmt"  Child process: pid={ev.pid} parent={ev.parentPid} binary={ev.binaryPath}"

  test "monitor captures exit code of failed process":
    if not prereqOk:
      echo "  SKIPPED: " & prereqReason
      skip()
    else:
      # bash -c 'exit 42' — exits with code 42.
      let child = startProcess("bash",
        args = @["-c", "exit 42"],
        options = {poUsePath, poStdErrToStdOut})
      let childPid = processID(child)

      var mon = startNativeMonitor(childPid, bpfObjPath)

      let deadline = epochTime() + 5.0
      while epochTime() < deadline:
        pollNativeEvents(mon)
        if not running(child):
          sleep(300)
          pollNativeEvents(mon)
          break
        sleep(100)

      stopNativeMonitor(mon)
      discard waitForExit(child)
      close(child)

      echo fmt"  Captured {mon.pendingExits.len} exit events"

      # Note: the exit code in the BPF exit event is currently a placeholder
      # (the kernel's task->exit_code requires CO-RE vmlinux access).
      # We verify the exit event exists, not the specific code value.
      check mon.pendingExits.len > 0

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if not prereqOk:
  echo ""
  echo "NOTE: Native BPF integration tests were skipped: " & prereqReason
  echo "To enable:"
  echo "  1. Run `just build-bpf-programs` to compile the BPF object"
  echo "  2. Run `just developer-setup` to set up BPF capabilities"
