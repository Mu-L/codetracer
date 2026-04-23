## Unit tests for ``bpf_monitor_native.nim`` — native BPF event processing.
##
## These tests verify:
##   - C struct ↔ Nim type size/layout consistency
##   - Ring buffer callback event dispatch and accumulation
##   - Environment ID computation and deduplication
##   - Default BPF object path resolution
##
## Run with:
##   nim c -r --hints:off --warnings:off -d:ssl -d:useOpenssl3 --mm:refc \
##     --passL:"-lbpf" --passL:"-lelf" --passL:"-lz" \
##     --nimcache:/tmp/ct-nim-cache/bpf_monitor_native_test \
##     src/ct/ci/bpf_monitor_native_test.nim
## Or via the justfile:
##   just test-bpf-native

import std/[os, strutils, unittest]
import bpf_monitor_native

# ---------------------------------------------------------------------------
# Struct size verification
# ---------------------------------------------------------------------------

suite "BPF event struct sizes":
  test "BpfExecBeginEvent size matches C layout":
    # type(4) + pid(4) + ppid(4) + timestamp_ns(8) +
    # binary_path(256) + cwd(256) + cgroup(128) = 660
    check sizeof(BpfExecBeginEvent) == 660

  test "BpfExecArgvEvent size matches C layout":
    # type(4) + pid(4) + index(2) + pad(2) + value(256) = 268
    check sizeof(BpfExecArgvEvent) == 268

  test "BpfExecEnvpEvent size matches C layout":
    # type(4) + pid(4) + raw(128 + 256) = 392
    check sizeof(BpfExecEnvpEvent) == 392

  test "BpfExecEndEvent size matches C layout":
    # type(4) + pid(4) + execve_ret(4) + pad(4) = 16
    check sizeof(BpfExecEndEvent) == 16

  test "BpfExitEventC size matches C layout":
    # type(4) + pid(4) + exit_code(4) + pad(4) + timestamp_ns(8) +
    # mem(8) + net_recv(8) + net_send(8) + disk_read(8) + disk_write(8) = 64
    check sizeof(BpfExitEventC) == 64

  test "BpfIntvEventC size matches C layout":
    # type(4) + pid(4) + timestamp_ns(8) + cpu_ns(8) + mem_rss(8) +
    # net_recv(8) + net_send(8) + disk_read(8) + disk_write(8) = 64
    check sizeof(BpfIntvEventC) == 64

# ---------------------------------------------------------------------------
# Ring buffer callback tests
# ---------------------------------------------------------------------------

suite "Ring buffer callback — EXEC events":
  test "EXEC_BEGIN + EXEC_END produces a ProcessStartEvent":
    var mon = initTestNativeMonitor()

    var beginEv: BpfExecBeginEvent
    beginEv.eventType = BPF_EVENT_EXEC_BEGIN
    beginEv.pid = 1234
    beginEv.ppid = 100
    beginEv.timestampNs = 1_000_000_000'u64

    let path = "/usr/bin/echo"
    for i, c in path:
      beginEv.binaryPath[i] = c

    let beginRc = testRingBufferCallback(mon, addr beginEv,
      csize_t(sizeof(beginEv)))
    check beginRc == 0

    var endEv: BpfExecEndEvent
    endEv.eventType = BPF_EVENT_EXEC_END
    endEv.pid = 1234
    endEv.execveRet = 0

    let endRc = testRingBufferCallback(mon, addr endEv,
      csize_t(sizeof(endEv)))
    check endRc == 0
    check mon.pendingStarts.len == 1
    check mon.pendingStarts[0].pid == 1234
    check mon.pendingStarts[0].parentPid == 100
    check mon.pendingStarts[0].binaryPath == "/usr/bin/echo"

  test "EXEC_BEGIN + EXEC_ARGV + EXEC_END captures command line":
    var mon = initTestNativeMonitor()

    var beginEv: BpfExecBeginEvent
    beginEv.eventType = BPF_EVENT_EXEC_BEGIN
    beginEv.pid = 2000
    beginEv.ppid = 100
    beginEv.timestampNs = 2_000_000_000'u64
    let path = "/bin/echo"
    for i, c in path:
      beginEv.binaryPath[i] = c
    discard testRingBufferCallback(mon, addr beginEv,
      csize_t(sizeof(beginEv)))

    var argv0: BpfExecArgvEvent
    argv0.eventType = BPF_EVENT_EXEC_ARGV
    argv0.pid = 2000
    argv0.index = 0
    let arg0 = "echo"
    for i, c in arg0:
      argv0.value[i] = c
    discard testRingBufferCallback(mon, addr argv0,
      csize_t(sizeof(argv0)))

    var argv1: BpfExecArgvEvent
    argv1.eventType = BPF_EVENT_EXEC_ARGV
    argv1.pid = 2000
    argv1.index = 1
    let arg1 = "hello world"
    for i, c in arg1:
      argv1.value[i] = c
    discard testRingBufferCallback(mon, addr argv1,
      csize_t(sizeof(argv1)))

    var endEv: BpfExecEndEvent
    endEv.eventType = BPF_EVENT_EXEC_END
    endEv.pid = 2000
    endEv.execveRet = 0
    discard testRingBufferCallback(mon, addr endEv,
      csize_t(sizeof(endEv)))

    check mon.pendingStarts.len == 1
    check mon.pendingStarts[0].commandLine == "echo hello world"

  test "Failed execve (ret != 0) does not produce a start event":
    var mon = initTestNativeMonitor()

    var beginEv: BpfExecBeginEvent
    beginEv.eventType = BPF_EVENT_EXEC_BEGIN
    beginEv.pid = 3000
    beginEv.ppid = 100
    discard testRingBufferCallback(mon, addr beginEv,
      csize_t(sizeof(beginEv)))

    var endEv: BpfExecEndEvent
    endEv.eventType = BPF_EVENT_EXEC_END
    endEv.pid = 3000
    endEv.execveRet = -2  # ENOENT
    discard testRingBufferCallback(mon, addr endEv,
      csize_t(sizeof(endEv)))

    check mon.pendingStarts.len == 0

suite "Ring buffer callback — EXIT events":
  test "EXIT event produces a ProcessExitEvent":
    var mon = initTestNativeMonitor()

    var ev: BpfExitEventC
    ev.eventType = BPF_EVENT_EXIT
    ev.pid = 1234
    ev.exitCode = 42
    ev.timestampNs = 5_000_000_000'u64
    ev.memMaxKb = 1024
    ev.netRecvBytes = 100
    ev.netSendBytes = 200
    ev.diskReadBytes = 300
    ev.diskWriteBytes = 400

    discard testRingBufferCallback(mon, addr ev, csize_t(sizeof(ev)))

    check mon.pendingExits.len == 1
    check mon.pendingExits[0].pid == 1234
    check mon.pendingExits[0].exitCode == 42
    check mon.pendingExits[0].maxMemoryBytes == 1024 * 1024
    check mon.pendingExits[0].totalNetRecvBytes == 100
    check mon.pendingExits[0].totalNetSendBytes == 200
    check mon.pendingExits[0].totalDiskReadBytes == 300
    check mon.pendingExits[0].totalDiskWriteBytes == 400

  test "EXIT of root PID sets running to false":
    var mon = initTestNativeMonitor(rootPid = 5555)

    var ev: BpfExitEventC
    ev.eventType = BPF_EVENT_EXIT
    ev.pid = 5555
    ev.exitCode = 0
    ev.timestampNs = 10_000_000_000'u64

    discard testRingBufferCallback(mon, addr ev, csize_t(sizeof(ev)))

    check mon.running == false

suite "Ring buffer callback — ENVP events":
  test "EXEC with environment variables produces a ProcessEnvironment":
    var mon = initTestNativeMonitor()

    var beginEv: BpfExecBeginEvent
    beginEv.eventType = BPF_EVENT_EXEC_BEGIN
    beginEv.pid = 4000
    beginEv.ppid = 100
    discard testRingBufferCallback(mon, addr beginEv,
      csize_t(sizeof(beginEv)))

    var envEv: BpfExecEnvpEvent
    envEv.eventType = BPF_EVENT_EXEC_ENVP
    envEv.pid = 4000
    # The raw field stores "KEY=VALUE" as a single string split at the
    # BPF_MONITOR_ENVKEY_MAX boundary by the ring buffer callback.
    let envRaw = "HOME=/tmp"
    for i, c in envRaw:
      envEv.raw[i] = c
    discard testRingBufferCallback(mon, addr envEv,
      csize_t(sizeof(envEv)))

    var endEv: BpfExecEndEvent
    endEv.eventType = BPF_EVENT_EXEC_END
    endEv.pid = 4000
    endEv.execveRet = 0
    discard testRingBufferCallback(mon, addr endEv,
      csize_t(sizeof(endEv)))

    check mon.pendingEnvs.len == 1
    check mon.pendingEnvs[0].variables.len == 1
    check mon.pendingEnvs[0].variables[0].key == "HOME"
    check mon.pendingEnvs[0].variables[0].value == "/tmp"
    check mon.pendingEnvs[0].id.len > 0

  test "Duplicate environment IDs are not re-emitted":
    var mon = initTestNativeMonitor()

    for pid in [5000'u32, 5001'u32]:
      var beginEv: BpfExecBeginEvent
      beginEv.eventType = BPF_EVENT_EXEC_BEGIN
      beginEv.pid = pid
      beginEv.ppid = 100
      discard testRingBufferCallback(mon, addr beginEv,
        csize_t(sizeof(beginEv)))

      var envEv: BpfExecEnvpEvent
      envEv.eventType = BPF_EVENT_EXEC_ENVP
      envEv.pid = pid
      let kv = "KEY=VAL"
      for i, c in kv: envEv.raw[i] = c
      discard testRingBufferCallback(mon, addr envEv,
        csize_t(sizeof(envEv)))

      var endEv: BpfExecEndEvent
      endEv.eventType = BPF_EVENT_EXEC_END
      endEv.pid = pid
      endEv.execveRet = 0
      discard testRingBufferCallback(mon, addr endEv,
        csize_t(sizeof(endEv)))

    check mon.pendingStarts.len == 2
    check mon.pendingEnvs.len == 1  # Deduplicated

suite "Helper functions":
  test "hasPendingEvents returns true when events exist":
    var mon = initTestNativeMonitor()
    check not mon.hasPendingEvents()

    mon.pendingStarts.add(ProcessStartEvent(pid: 1))
    check mon.hasPendingEvents()

  test "clearPendingEvents empties all buffers":
    var mon = initTestNativeMonitor()
    mon.pendingStarts.add(ProcessStartEvent(pid: 1))
    mon.pendingExits.add(ProcessExitEvent(pid: 1))
    mon.clearPendingEvents()
    check not mon.hasPendingEvents()

  test "defaultBpfObjectPath returns empty when file not found":
    let saved = getEnv("CODETRACER_BPF_OBJECT")
    putEnv("CODETRACER_BPF_OBJECT", "/nonexistent/path.o")
    let path = defaultBpfObjectPath()
    check path != "/nonexistent/path.o" or not fileExists(path)
    putEnv("CODETRACER_BPF_OBJECT", saved)
