## Unit tests for ``bpf_monitor.nim`` — BPFTrace event parsing logic.
##
## These tests exercise the JSON parsing, event accumulation, timestamp
## conversion, and environment hashing without requiring a running bpftrace
## process. They feed synthetic BPFTrace JSON lines into a test monitor
## and verify the resulting event buffers.
##
## Run with:
##   nim c -r src/ct/ci/bpf_monitor_test.nim
## Or via the justfile:
##   just test-bpf-monitor

import std/[unittest, strutils, tables, math]
import bpf_monitor
import ci_api_client

# ---------------------------------------------------------------------------
# Helper: wraps a data string in the BPFTrace JSON envelope
# ---------------------------------------------------------------------------

proc bpfJson(data: string): string =
  ## Wraps a semicolon-delimited event string in the JSON envelope that
  ## bpftrace emits with ``-f json``.
  """{"type": "printf", "data": """ & "\"" & data & "\"" & "}"

# ---------------------------------------------------------------------------
# nsToIso8601
# ---------------------------------------------------------------------------

suite "nsToIso8601 — TAI nanosecond to ISO 8601 conversion":
  test "converts a known TAI timestamp to UTC":
    # 2024-01-01T00:00:00.000Z in Unix seconds is 1704067200.
    # In TAI nanoseconds: (1704067200 + 37) * 1_000_000_000
    let taiNs = (1704067200'i64 + 37) * 1_000_000_000'i64
    let iso = nsToIso8601(taiNs)
    check iso == "2024-01-01T00:00:00.000Z"

  test "preserves millisecond precision":
    let taiNs = (1704067200'i64 + 37) * 1_000_000_000'i64 + 123_000_000
    let iso = nsToIso8601(taiNs)
    check iso == "2024-01-01T00:00:00.123Z"

  test "sub-millisecond nanoseconds are truncated":
    let taiNs = (1704067200'i64 + 37) * 1_000_000_000'i64 + 999_999
    let iso = nsToIso8601(taiNs)
    # 999_999 ns < 1ms → should still be .000
    check iso == "2024-01-01T00:00:00.000Z"

# ---------------------------------------------------------------------------
# computeEnvId
# ---------------------------------------------------------------------------

suite "computeEnvId — SHA-256 content-addressed environment IDs":
  test "same variables in different order produce the same ID":
    let env1 = @[
      (key: "PATH", value: "/usr/bin"),
      (key: "HOME", value: "/home/user"),
    ]
    let env2 = @[
      (key: "HOME", value: "/home/user"),
      (key: "PATH", value: "/usr/bin"),
    ]
    check computeEnvId(env1) == computeEnvId(env2)

  test "different values produce different IDs":
    let env1 = @[(key: "HOME", value: "/home/alice")]
    let env2 = @[(key: "HOME", value: "/home/bob")]
    check computeEnvId(env1) != computeEnvId(env2)

  test "empty environment produces a stable hash":
    let id1 = computeEnvId(@[])
    let id2 = computeEnvId(@[])
    check id1 == id2
    check id1.len > 0  # should be a hex string

  test "ID is a valid lowercase hex string":
    let env = @[(key: "FOO", value: "bar")]
    let id = computeEnvId(env)
    for c in id:
      check c in {'0'..'9', 'a'..'f', 'A'..'F'}

# ---------------------------------------------------------------------------
# parseBpfLine — EXEC events
# ---------------------------------------------------------------------------

suite "parseBpfLine — EXEC event parsing":
  test "complete EXEC sequence produces a ProcessStartEvent":
    var mon = initTestMonitor()
    let pid = 1234
    let ppid = 5678
    # TAI timestamp: (1704067200 + 37) * 1e9 = known epoch
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    mon.parseBpfLine(bpfJson("EXEC;BEGIN;" & $pid & ";" & $ppid & ";" & taiNs & ";/usr/bin/bash"))
    mon.parseBpfLine(bpfJson("EXEC;DIR;" & $pid & ";d;ld;home"))
    mon.parseBpfLine(bpfJson("EXEC;DIR;" & $pid & ";d;ld;user"))
    mon.parseBpfLine(bpfJson("EXEC;ARGV;" & $pid & ";d;ld;bash"))
    mon.parseBpfLine(bpfJson("EXEC;ARGV;" & $pid & ";d;ld;-c"))
    mon.parseBpfLine(bpfJson("EXEC;ARGV;" & $pid & ";d;ld;echo hello"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;" & $pid & ";d;ld;HOME=/home/user"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;" & $pid & ";d;ld;PATH=/usr/bin"))
    mon.parseBpfLine(bpfJson("EXEC;END;" & $pid))

    check mon.pendingStarts.len == 1
    let ev = mon.pendingStarts[0]
    check ev.pid == pid
    check ev.parentPid == ppid
    check ev.binaryPath == "/usr/bin/bash"
    check ev.commandLine == "bash -c echo hello"
    # DIR parts are reversed: ["home", "user"] → "/user/home"
    check ev.workingDirectory == "/user/home"
    check ev.startedAt == "2024-01-01T00:00:00.000Z"

  test "EXEC produces environment with content-addressed ID":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;1;" & taiNs & ";/bin/ls"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;100;d;ld;HOME=/root"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;100;d;ld;TERM=xterm"))
    mon.parseBpfLine(bpfJson("EXEC;END;100"))

    check mon.pendingEnvs.len == 1
    check mon.pendingEnvs[0].variables.len == 2
    check mon.pendingStarts[0].environmentId == mon.pendingEnvs[0].id
    check mon.pendingStarts[0].environmentId.len > 0

  test "duplicate environment is not re-sent":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    # First process with env HOME=/root
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;1;" & taiNs & ";/bin/ls"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;100;d;ld;HOME=/root"))
    mon.parseBpfLine(bpfJson("EXEC;END;100"))

    # Second process with identical env
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;200;1;" & taiNs & ";/bin/cat"))
    mon.parseBpfLine(bpfJson("EXEC;ENVP;200;d;ld;HOME=/root"))
    mon.parseBpfLine(bpfJson("EXEC;END;200"))

    check mon.pendingStarts.len == 2
    # Environment should only be sent once
    check mon.pendingEnvs.len == 1
    # Both starts reference the same environment ID
    check mon.pendingStarts[0].environmentId == mon.pendingStarts[1].environmentId

  test "EXEC;END without matching BEGIN is silently ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine(bpfJson("EXEC;END;9999"))
    check mon.pendingStarts.len == 0

  test "EXEC;BEGIN with too few fields is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;200"))
    # Missing timestamp and binary — should not create accumulator
    mon.parseBpfLine(bpfJson("EXEC;END;100"))
    check mon.pendingStarts.len == 0

  test "EXEC without ENVP produces empty environmentId":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;1;" & taiNs & ";/bin/true"))
    mon.parseBpfLine(bpfJson("EXEC;END;100"))

    check mon.pendingStarts.len == 1
    check mon.pendingStarts[0].environmentId == ""
    check mon.pendingEnvs.len == 0

  test "EXEC with CGROUP parts are accumulated":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;1;" & taiNs & ";/bin/sh"))
    mon.parseBpfLine(bpfJson("EXEC;CGROUP;100;d;ld;user.slice"))
    mon.parseBpfLine(bpfJson("EXEC;DIR;100;d;ld;tmp"))
    mon.parseBpfLine(bpfJson("EXEC;END;100"))

    check mon.pendingStarts.len == 1
    check mon.pendingStarts[0].workingDirectory == "/tmp"

# ---------------------------------------------------------------------------
# parseBpfLine — EXIT events
# ---------------------------------------------------------------------------

suite "parseBpfLine — EXIT event parsing":
  test "EXIT line produces a ProcessExitEvent with all fields":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    # EXIT;pid;timestamp_ns;exit_code;max_mem;net_recv;net_send;disk_read;disk_write;cpu_time;execve_return_code
    mon.parseBpfLine(bpfJson("EXIT;1234;" & taiNs & ";0;104857600;1024;2048;4096;8192;500000000;0"))

    check mon.pendingExits.len == 1
    let ev = mon.pendingExits[0]
    check ev.pid == 1234
    check ev.exitCode == 0
    check ev.exitedAt == "2024-01-01T00:00:00.000Z"
    check ev.maxMemoryBytes == 104857600  # 100 MB
    check ev.totalNetRecvBytes == 1024
    check ev.totalNetSendBytes == 2048
    check ev.totalDiskReadBytes == 4096
    check ev.totalDiskWriteBytes == 8192
    check ev.cpuTimeNs == 500000000

  test "EXIT with non-zero exit code":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXIT;5678;" & taiNs & ";137;0;0;0;0;0;0;0"))

    check mon.pendingExits.len == 1
    check mon.pendingExits[0].exitCode == 137

  test "EXIT with too few fields is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine(bpfJson("EXIT;1234;100;0"))
    check mon.pendingExits.len == 0

# ---------------------------------------------------------------------------
# parseBpfLine — INTV (interval metrics) events
# ---------------------------------------------------------------------------

suite "parseBpfLine — INTV interval metrics parsing":
  test "complete interval window produces ProcessMetricsEvents":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    # CPU usage: 250_000_000 ns out of 500_000_000 ns interval = 50%
    mon.parseBpfLine(bpfJson("INTV;CPU;1234;250000000;"))
    mon.parseBpfLine(bpfJson("INTV;MEM;1234;1048576;"))
    mon.parseBpfLine(bpfJson("INTV;NETR;1234;512;"))
    mon.parseBpfLine(bpfJson("INTV;NETW;1234;256;"))
    mon.parseBpfLine(bpfJson("INTV;DSKR;1234;4096;"))
    mon.parseBpfLine(bpfJson("INTV;DSKW;1234;2048;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs))

    check mon.pendingMetrics.len == 1
    let m = mon.pendingMetrics[0]
    check m.pid == 1234
    check m.timestamp == "2024-01-01T00:00:00.000Z"
    check abs(m.cpuPercent - 50.0) < 0.01
    check m.memoryBytes == 1048576
    check m.netRecvBytes == 512
    check m.netSendBytes == 256
    check m.diskReadBytes == 4096
    check m.diskWriteBytes == 2048

  test "interval with multiple PIDs produces one event per PID":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    mon.parseBpfLine(bpfJson("INTV;CPU;100;100000000;"))
    mon.parseBpfLine(bpfJson("INTV;MEM;100;2048;"))
    mon.parseBpfLine(bpfJson("INTV;CPU;200;400000000;"))
    mon.parseBpfLine(bpfJson("INTV;MEM;200;4096;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs))

    check mon.pendingMetrics.len == 2

    # Find events by PID (order is not guaranteed due to Table iteration)
    var ev100, ev200: ProcessMetricsEvent
    for m in mon.pendingMetrics:
      if m.pid == 100: ev100 = m
      elif m.pid == 200: ev200 = m

    check abs(ev100.cpuPercent - 20.0) < 0.01  # 100M / 500M * 100
    check ev100.memoryBytes == 2048
    check abs(ev200.cpuPercent - 80.0) < 0.01  # 400M / 500M * 100
    check ev200.memoryBytes == 4096

  test "accumulators reset after END — second interval is independent":
    var mon = initTestMonitor()
    let taiNs1 = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    let taiNs2 = $(int64((1704067201 + 37) * 1_000_000_000'i64))

    mon.parseBpfLine(bpfJson("INTV;CPU;100;250000000;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs1))

    check mon.pendingMetrics.len == 1

    # Second interval — different PID
    mon.parseBpfLine(bpfJson("INTV;CPU;200;100000000;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs2))

    check mon.pendingMetrics.len == 2
    # PID 100 should NOT appear in the second interval
    check mon.pendingMetrics[1].pid == 200

  test "LE (last event) PID without CPU/MEM is skipped":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    # PID 999 only has a "last event" marker (process already exited)
    mon.parseBpfLine(bpfJson("INTV;LE;999;1;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs))

    check mon.pendingMetrics.len == 0

  test "LE PID with CPU data is NOT skipped":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))

    mon.parseBpfLine(bpfJson("INTV;LE;999;1;"))
    mon.parseBpfLine(bpfJson("INTV;CPU;999;100000000;"))
    mon.parseBpfLine(bpfJson("INTV;END;0;" & taiNs))

    check mon.pendingMetrics.len == 1
    check mon.pendingMetrics[0].pid == 999

# ---------------------------------------------------------------------------
# parseBpfLine — JSON envelope handling
# ---------------------------------------------------------------------------

suite "parseBpfLine — JSON envelope and edge cases":
  test "non-printf type is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine("""{"type": "map", "data": "something"}""")
    check mon.pendingStarts.len == 0
    check mon.pendingExits.len == 0
    check mon.pendingMetrics.len == 0

  test "malformed JSON is silently ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine("{not valid json")
    check mon.pendingStarts.len == 0

  test "line not starting with type field is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine("some random bpftrace output")
    check mon.pendingStarts.len == 0

  test "unknown event type is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine(bpfJson("WRITE;BE-ND;100;100;123456;1;1;hello world"))
    check mon.pendingStarts.len == 0
    check mon.pendingExits.len == 0
    check mon.pendingMetrics.len == 0

  test "empty data string is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine("""{"type": "printf", "data": ""}""")
    check mon.pendingStarts.len == 0

  test "data with single field (no semicolons) is ignored":
    var mon = initTestMonitor()
    mon.parseBpfLine(bpfJson("SOLO"))
    check mon.pendingStarts.len == 0

# ---------------------------------------------------------------------------
# hasPendingEvents
# ---------------------------------------------------------------------------

suite "hasPendingEvents":
  test "returns false for freshly initialized monitor":
    var mon = initTestMonitor()
    check not hasPendingEvents(mon)

  test "returns true after parsing an EXIT event":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXIT;1234;" & taiNs & ";0;0;0;0;0;0;0;0"))
    check hasPendingEvents(mon)

  test "returns true after parsing a complete EXEC sequence":
    var mon = initTestMonitor()
    let taiNs = $(int64((1704067200 + 37) * 1_000_000_000'i64))
    mon.parseBpfLine(bpfJson("EXEC;BEGIN;100;1;" & taiNs & ";/bin/true"))
    mon.parseBpfLine(bpfJson("EXEC;END;100"))
    check hasPendingEvents(mon)
