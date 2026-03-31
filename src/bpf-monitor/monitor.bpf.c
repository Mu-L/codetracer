// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
/*
 * CodeTracer BPF process monitor — kernel-side programs.
 *
 * Attaches to execve and process exit tracepoints to capture process lifecycle
 * events for a monitored process tree. Events are sent to userspace via a ring
 * buffer and consumed by the Nim bpf_monitor_native module.
 *
 * The root PID is seeded into the `process_tracked` map by userspace before
 * any tracepoints fire. Child processes are automatically tracked when their
 * parent is in the map (via execve interception).
 *
 * Phase 1: EXEC (sys_enter_execve, sys_exit_execve) + EXIT (sched_process_exit)
 * Phase 2 (future): Interval metrics (CPU, memory, network, disk accumulators)
 *
 * Build:
 *   clang -target bpf -D__TARGET_ARCH_x86 -I src/bpf-monitor \
 *         -O2 -g -c src/bpf-monitor/monitor.bpf.c -o monitor.bpf.o
 *
 * References:
 *   - https://docs.kernel.org/bpf/libbpf/program_types.html
 *   - https://nakryiko.com/posts/bpf-ringbuf/
 *   - https://github.com/libbpf/libbpf-bootstrap/tree/master/examples/c
 */

#include "vmlinux_minimal.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

/* __BPF__ is automatically defined by clang when targeting BPF.
 * events.h checks for it to use kernel types instead of <stdint.h>. */
#include "events.h"

/* -------------------------------------------------------------------------
 * Tunables
 * ------------------------------------------------------------------------- */

/* Maximum number of argv elements to capture per execve.
 * Keep small to avoid BPF verifier "jump sequence too complex" errors.
 * The verifier tracks all possible branch paths; large loop bounds
 * combined with conditional logic inside the loop body can exceed the
 * 8192-jump complexity limit. 32 covers the vast majority of real
 * command lines while staying well within verifier limits. */
#define MAX_ARGV_COUNT 32

/* Maximum number of envp elements to capture per execve.
 * See MAX_ARGV_COUNT comment for verifier complexity rationale. */
#define MAX_ENVP_COUNT 32

/* Ring buffer size — must be a power of 2.
 * 256 KB should be sufficient for normal process trees. */
#define RINGBUF_SIZE (256 * 1024)

/* -------------------------------------------------------------------------
 * BPF Maps
 * ------------------------------------------------------------------------- */

/*
 * PID filter map — only events for PIDs in this map are emitted.
 * Seeded by userspace with the root PID. Child PIDs are added by the
 * execve handler when the parent PID is tracked.
 *
 * Key: uint32_t (PID / tgid)
 * Value: uint8_t (1 = tracked)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 8192);
    __type(key, u32);
    __type(value, u8);
} process_tracked SEC(".maps");

/*
 * Ring buffer for kernel → userspace event delivery.
 * All event types (EXEC_BEGIN, EXEC_ARGV, EXEC_ENVP, EXEC_END, EXIT)
 * are written here and consumed by ring_buffer__poll() in Nim.
 */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, RINGBUF_SIZE);
} events SEC(".maps");

/*
 * Stash map for execve return codes.
 * sys_enter_execve stores the PID, and sys_exit_execve reads the return
 * code. We need this intermediate map because the exit tracepoint fires
 * in a different context than the enter.
 *
 * Key: uint32_t (PID / tgid)
 * Value: uint8_t (1 = pending execve)
 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 4096);
    __type(key, u32);
    __type(value, u8);
} execve_pending SEC(".maps");

/* -------------------------------------------------------------------------
 * Helper: check if a PID is tracked
 * ------------------------------------------------------------------------- */

static __always_inline bool is_tracked(u32 pid)
{
    return bpf_map_lookup_elem(&process_tracked, &pid) != NULL;
}

static __always_inline void track_pid(u32 pid)
{
    u8 val = 1;
    bpf_map_update_elem(&process_tracked, &pid, &val, BPF_ANY);
}

static __always_inline void untrack_pid(u32 pid)
{
    bpf_map_delete_elem(&process_tracked, &pid);
}

/* -------------------------------------------------------------------------
 * Helper: read cgroup path for the current task
 *
 * Reads the cgroup v2 path from the task's css_set. This is a best-effort
 * read — if the cgroup hierarchy is not available, the buffer is left empty.
 * ------------------------------------------------------------------------- */

static __always_inline void read_cgroup(char *buf, int buf_size)
{
    /* Zero-initialize to ensure null termination if read fails. */
    __builtin_memset(buf, 0, buf_size);

    /* BPF doesn't have a direct helper to read the cgroup path as a string.
     * bpf_get_current_cgroup_id() returns a numeric ID, not a path.
     * Leave the cgroup field empty — userspace can read /proc/<pid>/cgroup
     * if the cgroup path is needed. */
}

/* -------------------------------------------------------------------------
 * Helper: read current working directory from task_struct
 *
 * Navigates task->fs->pwd.dentry->d_name to reconstruct the cwd path.
 * This is limited to the last path component only (full path reconstruction
 * would require walking d_parent, which is complex in BPF). For full cwd,
 * the userspace side can read /proc/<pid>/cwd.
 * ------------------------------------------------------------------------- */

static __always_inline void read_cwd(char *buf, int buf_size)
{
    __builtin_memset(buf, 0, buf_size);

    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (!task)
        return;

    /* We can't easily walk the full dentry path in BPF. Instead, we'll
     * leave this for userspace to fill in via /proc/<pid>/cwd if needed.
     * The BPF program just provides an empty string here. */
}

/* -------------------------------------------------------------------------
 * Tracepoint: syscalls/sys_enter_execve
 *
 * Fires when a process calls execve(). We emit:
 *   1. EXEC_BEGIN with binary path, cwd, cgroup, timestamp
 *   2. EXEC_ARGV × N for each argv element
 *   3. EXEC_ENVP × N for each environment variable
 *
 * The EXEC_END event is emitted by the sys_exit_execve handler.
 * ------------------------------------------------------------------------- */

SEC("tracepoint/syscalls/sys_enter_execve")
int handle_execve_enter(struct trace_event_raw_sys_enter_execve *ctx)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;  /* tgid = userspace PID */
    u32 ppid;

    /* Check if the parent is tracked (for child process auto-tracking).
     * Also check if this PID itself is tracked (re-exec case). */
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (!task)
        return 0;

    ppid = BPF_CORE_READ(task, real_parent, tgid);

    if (!is_tracked(pid) && !is_tracked(ppid))
        return 0;

    /* Track this PID (may already be tracked, that's fine). */
    track_pid(pid);

    /* Mark that this PID has a pending execve (for sys_exit_execve). */
    u8 pending = 1;
    bpf_map_update_elem(&execve_pending, &pid, &pending, BPF_ANY);

    /* --- Emit EXEC_BEGIN --- */
    struct bpf_exec_begin_event *begin;
    begin = bpf_ringbuf_reserve(&events, sizeof(*begin), 0);
    if (!begin)
        return 0;

    begin->type = BPF_EVENT_EXEC_BEGIN;
    begin->pid = pid;
    begin->ppid = ppid;
    begin->timestamp_ns = bpf_ktime_get_ns();

    /* Read the executable filename from user memory. */
    const char *filename = ctx->filename;
    if (filename) {
        bpf_probe_read_user_str(begin->binary_path, sizeof(begin->binary_path),
                                filename);
    } else {
        begin->binary_path[0] = '\0';
    }

    /* CWD: leave empty for userspace to fill via /proc/<pid>/cwd. */
    read_cwd(begin->cwd, sizeof(begin->cwd));

    /* Cgroup path. */
    read_cgroup(begin->cgroup, sizeof(begin->cgroup));

    bpf_ringbuf_submit(begin, 0);

    /* --- Emit EXEC_ARGV events --- */
    const char *const *argv = ctx->argv;
    if (argv) {
        for (int i = 0; i < MAX_ARGV_COUNT; i++) {
            const char *argp = NULL;
            int ret = bpf_probe_read_user(&argp, sizeof(argp), &argv[i]);
            if (ret != 0 || argp == NULL)
                break;

            struct bpf_exec_argv_event *argv_ev;
            argv_ev = bpf_ringbuf_reserve(&events, sizeof(*argv_ev), 0);
            if (!argv_ev)
                break;

            argv_ev->type = BPF_EVENT_EXEC_ARGV;
            argv_ev->pid = pid;
            argv_ev->index = (u16)i;
            argv_ev->__pad = 0;
            bpf_probe_read_user_str(argv_ev->value, sizeof(argv_ev->value),
                                    argp);

            bpf_ringbuf_submit(argv_ev, 0);
        }
    }

    /* --- Emit EXEC_ENVP events ---
     * Each event carries the raw "KEY=VALUE" string; splitting into key/value
     * is done in userspace (Nim) to avoid nested loops that exceed the BPF
     * verifier's 8192-jump complexity limit. */
    const char *const *envp = ctx->envp;
    if (envp) {
        for (int i = 0; i < MAX_ENVP_COUNT; i++) {
            const char *envstr = NULL;
            int ret = bpf_probe_read_user(&envstr, sizeof(envstr), &envp[i]);
            if (ret != 0 || envstr == NULL)
                break;

            struct bpf_exec_envp_event *envp_ev;
            envp_ev = bpf_ringbuf_reserve(&events, sizeof(*envp_ev), 0);
            if (!envp_ev)
                break;

            envp_ev->type = BPF_EVENT_EXEC_ENVP;
            envp_ev->pid = pid;
            bpf_probe_read_user_str(envp_ev->raw, sizeof(envp_ev->raw),
                                    envstr);

            bpf_ringbuf_submit(envp_ev, 0);
        }
    }

    return 0;
}

/* -------------------------------------------------------------------------
 * Tracepoint: syscalls/sys_exit_execve
 *
 * Fires after execve() returns. Emits EXEC_END with the return code.
 * On success (ret == 0), the process image has been replaced.
 * On failure (ret < 0), the original process continues.
 * ------------------------------------------------------------------------- */

SEC("tracepoint/syscalls/sys_exit_execve")
int handle_execve_exit(struct trace_event_raw_sys_exit_execve *ctx)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;

    /* Only emit EXEC_END if we have a pending execve for this PID. */
    u8 *pending = bpf_map_lookup_elem(&execve_pending, &pid);
    if (!pending)
        return 0;

    bpf_map_delete_elem(&execve_pending, &pid);

    struct bpf_exec_end_event *end;
    end = bpf_ringbuf_reserve(&events, sizeof(*end), 0);
    if (!end)
        return 0;

    end->type = BPF_EVENT_EXEC_END;
    end->pid = pid;
    end->execve_ret = (s32)ctx->ret;
    end->__pad = 0;

    bpf_ringbuf_submit(end, 0);

    return 0;
}

/* -------------------------------------------------------------------------
 * Tracepoint: sched/sched_process_exit
 *
 * Fires when a process exits. Emits an EXIT event with the exit code
 * and cumulative resource usage (from accumulator maps in Phase 2).
 * Also removes the PID from the tracking map.
 * ------------------------------------------------------------------------- */

SEC("tracepoint/sched/sched_process_exit")
int handle_sched_exit(struct trace_event_raw_sched_process_exit *ctx)
{
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 pid = pid_tgid >> 32;

    if (!is_tracked(pid))
        return 0;

    struct bpf_exit_event *ev;
    ev = bpf_ringbuf_reserve(&events, sizeof(*ev), 0);
    if (!ev)
        goto cleanup;

    ev->type = BPF_EVENT_EXIT;
    ev->pid = pid;
    ev->__pad = 0;
    ev->timestamp_ns = bpf_ktime_get_ns();

    /* Read exit code from the current task.
     * The kernel stores (exit_code << 8 | signal), but for the tracepoint
     * context, we read it from the task_struct for accuracy. */
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (task) {
        /* task->exit_code contains (exit_code << 8 | signal_number).
         * We want just the exit code part. */
        int raw_exit;
        bpf_probe_read_kernel(&raw_exit, sizeof(raw_exit),
                              &task->pid);  /* placeholder — see note below */
        /* Note: reading task->exit_code via CO-RE would require it in
         * vmlinux_minimal.h. For now, we use the tracepoint's view of
         * the exit — the pid field from the tracepoint context is actually
         * the exiting thread's pid. The actual exit code is available
         * from /proc or from wait4() in userspace.
         *
         * TODO: Add exit_code to vmlinux_minimal.h for direct CO-RE read. */
        ev->exit_code = 0;  /* Placeholder — userspace reads real exit code */
    } else {
        ev->exit_code = 0;
    }

    /* Phase 2: Read and include resource accumulators here.
     * For now, zero-initialize the resource fields. */
    ev->mem_max_kb = 0;
    ev->net_recv_bytes = 0;
    ev->net_send_bytes = 0;
    ev->disk_read_bytes = 0;
    ev->disk_write_bytes = 0;

    bpf_ringbuf_submit(ev, 0);

cleanup:
    /* Remove the PID from tracking. */
    untrack_pid(pid);

    /* Also clean up any stale execve_pending entry. */
    bpf_map_delete_elem(&execve_pending, &pid);

    return 0;
}

/* License string required by the BPF verifier for programs that use
 * GPL-only helpers (bpf_probe_read_user_str, bpf_get_current_task, etc). */
char LICENSE[] SEC("license") = "GPL";
