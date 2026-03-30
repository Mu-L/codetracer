/* SPDX-License-Identifier: (LGPL-2.1 OR BSD-2-Clause) */
/*
 * Shared event struct definitions for CodeTracer's BPF process monitor.
 *
 * These structs define the binary format of events passed through the BPF
 * ring buffer from kernel BPF programs to the Nim userspace consumer.
 * They are used by both:
 *   - monitor.bpf.c  (kernel side, via #include)
 *   - bpf_monitor_native.nim  (userspace, via Nim {.importc.} + {.header.})
 *
 * Keep this header C99-compatible with no BPF-specific types so that it
 * can be included from both BPF and userspace compilation contexts.
 *
 * The EXEC event is split into multiple sub-events because the BPF stack is
 * limited to 512 bytes and argv/envp arrays are variable-length. The
 * userspace consumer reassembles them into a single ProcessStartEvent by
 * accumulating sub-events keyed by PID until EXEC_END arrives.
 *
 * Wire format: all structs are naturally aligned and packed by the compiler.
 * The first field (type) is always uint32_t, allowing the consumer to peek
 * at the event type before casting to the correct struct.
 */
#ifndef __BPF_MONITOR_EVENTS_H__
#define __BPF_MONITOR_EVENTS_H__

#ifdef __BPF__
/* BPF compilation context — types come from vmlinux_minimal.h.
 * Map stdint names to kernel type names so the struct definitions
 * work in both contexts without ifdefs on every field. */
typedef __u8  uint8_t;
typedef __u16 uint16_t;
typedef __u32 uint32_t;
typedef __u64 uint64_t;
typedef __s8  int8_t;
typedef __s16 int16_t;
typedef __s32 int32_t;
typedef __s64 int64_t;
#else
/* Userspace compilation context — use standard C types. */
#include <stdint.h>
#endif

/*
 * Event type discriminator.
 * Stored in the first uint32_t of every ring buffer event.
 */
enum bpf_event_type {
    BPF_EVENT_EXEC_BEGIN = 1, /* Start of a new execve — binary path, cwd, cgroup */
    BPF_EVENT_EXEC_ARGV  = 2, /* One argv element */
    BPF_EVENT_EXEC_ENVP  = 3, /* One environment variable (key=value) */
    BPF_EVENT_EXEC_END   = 4, /* End of execve — includes return code */
    BPF_EVENT_EXIT       = 5, /* Process exit — exit code + resource totals */
    BPF_EVENT_INTV       = 6, /* Interval metrics snapshot (Phase 2) */
};

/* Maximum sizes for string fields.
 * These match the bpftrace-collection.bt limits and are chosen to fit
 * within BPF helper read limits while keeping ring buffer entries small. */
#define BPF_MONITOR_PATH_MAX   256
#define BPF_MONITOR_CGROUP_MAX 128
#define BPF_MONITOR_ARG_MAX    256
#define BPF_MONITOR_ENVKEY_MAX 128
#define BPF_MONITOR_ENVVAL_MAX 256

/*
 * EXEC_BEGIN: Emitted on sys_enter_execve for tracked PIDs.
 * Contains the static per-process metadata. Followed by zero or more
 * EXEC_ARGV and EXEC_ENVP events, then an EXEC_END.
 */
struct bpf_exec_begin_event {
    uint32_t type;          /* BPF_EVENT_EXEC_BEGIN */
    uint32_t pid;           /* Process ID (tgid in kernel terms) */
    uint32_t ppid;          /* Parent process ID */
    uint64_t timestamp_ns;  /* ktime_get_ns() at execve entry */
    char binary_path[BPF_MONITOR_PATH_MAX]; /* Executable path (from filename arg) */
    char cwd[BPF_MONITOR_PATH_MAX];         /* Working directory at exec time */
    char cgroup[BPF_MONITOR_CGROUP_MAX];    /* Cgroup path (v2) */
};

/*
 * EXEC_ARGV: One element of the argv array.
 * Emitted in order (index 0, 1, 2, ...) up to a bounded limit.
 */
struct bpf_exec_argv_event {
    uint32_t type;          /* BPF_EVENT_EXEC_ARGV */
    uint32_t pid;           /* Process ID (same as EXEC_BEGIN) */
    uint16_t index;         /* Argv position (0-based) */
    uint16_t __pad;         /* Alignment padding */
    char value[BPF_MONITOR_ARG_MAX]; /* Null-terminated argv string */
};

/*
 * EXEC_ENVP: One environment variable from the execve envp array.
 * The BPF program splits "KEY=VALUE" into separate fields.
 */
struct bpf_exec_envp_event {
    uint32_t type;          /* BPF_EVENT_EXEC_ENVP */
    uint32_t pid;           /* Process ID (same as EXEC_BEGIN) */
    char key[BPF_MONITOR_ENVKEY_MAX];   /* Environment variable name */
    char value[BPF_MONITOR_ENVVAL_MAX]; /* Environment variable value */
};

/*
 * EXEC_END: Marks the end of an execve event sequence.
 * Includes the execve return code (0 = success, negative = errno).
 */
struct bpf_exec_end_event {
    uint32_t type;          /* BPF_EVENT_EXEC_END */
    uint32_t pid;           /* Process ID */
    int32_t  execve_ret;    /* Return code from execve (0 or -errno) */
    uint32_t __pad;         /* Alignment padding */
};

/*
 * EXIT: Emitted on sched_process_exit for tracked PIDs.
 * Contains the process exit code and cumulative resource usage.
 */
struct bpf_exit_event {
    uint32_t type;          /* BPF_EVENT_EXIT */
    uint32_t pid;           /* Process ID */
    int32_t  exit_code;     /* Exit code (from task->exit_code >> 8) */
    uint32_t __pad;         /* Alignment padding */
    uint64_t timestamp_ns;  /* ktime_get_ns() at exit */
    uint64_t mem_max_kb;    /* Peak RSS in KB (from resource accumulators) */
    uint64_t net_recv_bytes;
    uint64_t net_send_bytes;
    uint64_t disk_read_bytes;
    uint64_t disk_write_bytes;
};

/*
 * INTV: Periodic interval metrics snapshot (Phase 2).
 * Emitted by userspace every 500ms after reading BPF accumulator maps.
 */
struct bpf_intv_event {
    uint32_t type;          /* BPF_EVENT_INTV */
    uint32_t pid;           /* Process ID */
    uint64_t timestamp_ns;  /* ktime_get_ns() or userspace timestamp */
    uint64_t cpu_ns;        /* CPU time in nanoseconds over the interval.
                             * Userspace converts to percent: cpu_ns / interval_ns * 100.
                             * BPF doesn't support floating point, so we pass raw ns. */
    uint64_t mem_rss_kb;    /* Current RSS in KB */
    uint64_t net_recv_bytes;
    uint64_t net_send_bytes;
    uint64_t disk_read_bytes;
    uint64_t disk_write_bytes;
};

#endif /* __BPF_MONITOR_EVENTS_H__ */
