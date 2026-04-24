/**
 * Multi-trace loading test: loads different traces into separate sessions.
 *
 * Proves that:
 *   1. Multiple traces can be pre-recorded and loaded into distinct sessions.
 *   2. Each session holds the correct trace metadata (program name, source path).
 *   3. Switching between sessions preserves per-session trace identity.
 *   4. The editor displays the correct source file for each session.
 *
 * ## Trace types covered
 *
 * - **Materialized (DB-based)**: Python programs recorded via the Python
 *   recorder (py_console_logs, py_checklist).  Always available.
 * - **MCR (native recorder)**: C/Rust programs recorded via codetracer-native-
 *   recorder.  Requires `CODETRACER_RR_BACKEND_PATH` or
 *   `CODETRACER_RR_BACKEND_PRESENT` environment variable.
 * - **RR**: Uses the rr time-travel debugger as the recording backend.
 *   Same prerequisite as MCR.
 *
 * The base test uses two materialized Python traces (always works).  An
 * extended test conditionally adds an RR/MCR trace when the backend is
 * available.
 *
 * ## How loading into a new session works
 *
 * 1. Pre-record programs via `ct record` (returns trace IDs).
 * 2. Launch Electron with trace A (CODETRACER_TRACE_ID env var).
 * 3. Click "+" to create a new session (tab).
 * 4. From the renderer, send `CODETRACER::load-recent-trace` IPC with
 *    trace B's ID.  The main process starts a replay for trace B and
 *    sends `CODETRACER::trace-loaded` back to the renderer, which
 *    stores the trace in the active session.
 * 5. Verify session metadata and editor content.
 *
 * ## Known limitation
 *
 * Loading a trace into session 1 stops the replay for session 0
 * (`prepareForLoadingTrace` calls `ct/stop-replay`).  This means
 * session 0's DAP connection is broken after session 1 loads its trace.
 * Stepping in session 0 will not work until the replay is restarted.
 * This test verifies trace metadata and source file correctness, not
 * DAP stepping across sessions.
 */

import * as path from "node:path";

import { test, expect, recordTestProgram, testProgramsPath } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Helpers — session introspection via window.data
// ---------------------------------------------------------------------------

/** Return the number of sessions in the data model. */
async function getSessionCount(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

/** Return the activeSessionIndex from window.data. */
async function getActiveIndex(page: import("@playwright/test").Page): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.activeSessionIndex ?? -1;
  });
}

/** Return trace metadata for a specific session. */
async function getSessionTrace(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<{ id: number; program: string; outputFolder: string } | null> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    const session = d?.sessions?.[idx];
    const trace = session?.trace;
    if (!trace) return null;
    return {
      id: Number(trace.id ?? -1),
      program: String(trace.program ?? ""),
      outputFolder: String(trace.outputFolder ?? ""),
    };
  }, sessionIndex);
}

/** Return whether a session has a loaded trace. */
async function sessionHasTrace(
  page: import("@playwright/test").Page,
  sessionIndex: number,
): Promise<boolean> {
  return page.evaluate((idx) => {
    const d = (window as any).data;
    return !!d?.sessions?.[idx]?.trace;
  }, sessionIndex);
}

/**
 * Load a pre-recorded trace into the currently active session by sending
 * the `CODETRACER::load-recent-trace` IPC message from the renderer to
 * the main process.
 *
 * The main process will:
 *   1. Look up trace metadata from the trace database.
 *   2. Start a replay backend for the trace.
 *   3. Send `CODETRACER::init` and `CODETRACER::trace-loaded` to the
 *      renderer, which stores the data in the active session.
 */
async function loadTraceIntoActiveSession(
  page: import("@playwright/test").Page,
  traceId: number,
): Promise<void> {
  await page.evaluate((id) => {
    const d = (window as any).data;
    d.ipc.send("CODETRACER::load-recent-trace", { traceId: id });
  }, traceId);
}

/**
 * Wait for the editor component to show a file matching the given substring.
 * Returns the matched filename or throws after timeout.
 */
async function waitForEditorFile(
  page: import("@playwright/test").Page,
  fileSubstring: string,
  timeoutMs = 30_000,
): Promise<string> {
  let fileName = "";
  const delayMs = 500;
  const maxAttempts = Math.ceil(timeoutMs / delayMs);
  await retry(
    async () => {
      // Check all editor component data-label attributes.
      const labels: string[] = await page.evaluate(() => {
        const editors = document.querySelectorAll("div[id^='editorComponent']");
        return Array.from(editors).map((el) => el.getAttribute("data-label") ?? "");
      });
      for (const label of labels) {
        if (label.includes(fileSubstring)) {
          const segments = label.split("/").filter(Boolean);
          fileName = segments[segments.length - 1] ?? label;
          return true;
        }
      }
      return false;
    },
    { maxAttempts, delayMs },
  );
  return fileName;
}

// ---------------------------------------------------------------------------
// Suite: multi-trace loading into sessions
// ---------------------------------------------------------------------------

test.describe("Multi-trace loading into sessions", () => {
  test.setTimeout(300_000); // 5 minutes: multiple recordings + Electron + IPC
  test.describe.configure({ retries: 1 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: load two materialized traces into separate sessions
  //
  // This is the baseline test that always works (no RR/MCR needed).
  // Records py_console_logs (trace A) and py_checklist (trace B), loads
  // each into its own session, and verifies per-session isolation.
  // -------------------------------------------------------------------------

  test("load two materialized traces into separate sessions", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);

    // ==================================================================
    // Phase 1: Wait for the first trace (py_console_logs) to fully load
    // ==================================================================

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    // Confirm session 0 is active and has a trace.
    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await getActiveIndex(ctPage)).toBe(0);
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);

    // Verify session 0's trace is py_console_logs.
    const trace0 = await getSessionTrace(ctPage, 0);
    expect(trace0).not.toBeNull();
    expect(trace0!.program).toContain("main.py");
    console.log(`# session 0 trace: id=${trace0!.id} program=${trace0!.program}`);

    // Verify editor shows main.py.
    const editor0File = await waitForEditorFile(ctPage, "main.py");
    expect(editor0File).toContain("main.py");

    // ==================================================================
    // Phase 2: Pre-record the second trace (py_checklist/basics.py)
    // ==================================================================

    const secondProgramPath = path.join(testProgramsPath, "py_checklist", "basics.py");
    const secondTraceId = recordTestProgram(secondProgramPath);
    console.log(`# pre-recorded second trace: id=${secondTraceId} (py_checklist/basics.py)`);

    // ==================================================================
    // Phase 3: Create a new session and load the second trace
    // ==================================================================

    // Click "+" to create session 1.
    await ctPage.locator(".session-tab-add").click();

    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(1);

    // Session 1 should be empty (no trace yet).
    expect(await sessionHasTrace(ctPage, 1)).toBe(false);

    // Load the second trace into session 1 via IPC.
    await loadTraceIntoActiveSession(ctPage, secondTraceId);

    // Wait for session 1 to receive the trace.
    await retry(
      async () => await sessionHasTrace(ctPage, 1),
      { maxAttempts: 60, delayMs: 1000 },
    );

    // Verify session 1's trace is py_checklist/basics.py.
    const trace1 = await getSessionTrace(ctPage, 1);
    expect(trace1).not.toBeNull();
    expect(trace1!.program).toContain("basics.py");
    expect(trace1!.id).toBe(secondTraceId);
    console.log(`# session 1 trace: id=${trace1!.id} program=${trace1!.program}`);

    // Verify the two traces are different.
    expect(trace0!.id).not.toBe(trace1!.id);
    expect(trace0!.program).not.toBe(trace1!.program);

    // Wait for editor to show basics.py in session 1.
    const editor1File = await waitForEditorFile(ctPage, "basics.py");
    expect(editor1File).toContain("basics.py");

    // ==================================================================
    // Phase 4: Verify session isolation — session 0's trace is preserved
    // ==================================================================

    // Session 0 should still have its original trace in the data model.
    const trace0AfterLoad = await getSessionTrace(ctPage, 0);
    expect(trace0AfterLoad).not.toBeNull();
    expect(trace0AfterLoad!.program).toContain("main.py");
    expect(trace0AfterLoad!.id).toBe(trace0!.id);

    // ==================================================================
    // Phase 5: Switch back to session 0 and verify editor content
    // ==================================================================

    // Click the first tab to switch back to session 0.
    await ctPage.locator(".session-tab").first().click();
    await ctPage.waitForTimeout(500);

    // Verify active index switched.  Fall back to JS call if Karax click
    // didn't fire (known issue after GL destroy/recreate).
    let activeAfterClick = await getActiveIndex(ctPage);
    if (activeAfterClick !== 0) {
      await ctPage.evaluate(() => {
        const d = (window as any).data;
        const fns = Object.getOwnPropertyNames(window).filter(
          (n) => n.startsWith("switchSession__"),
        );
        if (fns.length > 0) {
          (window as any)[fns[0]](d, 0);
        }
      });
      await ctPage.waitForTimeout(2000);
      activeAfterClick = await getActiveIndex(ctPage);
    }
    expect(activeAfterClick).toBe(0);

    // Session 0's trace metadata should still be correct.
    const trace0Final = await getSessionTrace(ctPage, 0);
    expect(trace0Final).not.toBeNull();
    expect(trace0Final!.program).toContain("main.py");
    expect(trace0Final!.id).toBe(trace0!.id);

    // Wait for GL rebuild and verify editor shows main.py again.
    await retry(
      async () => {
        const labels: string[] = await ctPage.evaluate(() => {
          const editors = document.querySelectorAll("div[id^='editorComponent']");
          return Array.from(editors).map((el) => el.getAttribute("data-label") ?? "");
        });
        return labels.some((l) => l.includes("main.py"));
      },
      { maxAttempts: 30, delayMs: 500 },
    );

    console.log("# multi-trace load test passed: both sessions hold distinct traces");
  });

  // -------------------------------------------------------------------------
  // Test 2: three trace types (materialized + MCR + RR) in separate sessions
  //
  // This test loads three different trace types:
  //   - Session 0: Materialized (py_console_logs) — always available
  //   - Session 1: Materialized (noir_example) — DB-based Noir trace
  //   - Session 2: RR/MCR (c_sudoku_solver) — requires RR backend
  //
  // The test is skipped when the RR backend is not available.
  // -------------------------------------------------------------------------

  test("three trace types: materialized Python + Noir + RR C program", async ({ ctPage }, testInfo) => {
    // Skip if RR backend is not available.
    const hasRR = !!(process.env.CODETRACER_RR_BACKEND_PATH || process.env.CODETRACER_RR_BACKEND_PRESENT);
    if (!hasRR) {
      testInfo.skip(true, "RR backend not available — skipping multi-type trace test");
    }
    // Also skip if only running DB tests.
    if (process.env.CODETRACER_DB_TESTS_ONLY === "1") {
      testInfo.skip(true, "RR test skipped — running DB-based tests only");
    }

    const layout = new LayoutPage(ctPage);

    // ==================================================================
    // Phase 1: Session 0 — materialized Python trace (already loaded)
    // ==================================================================

    await layout.waitForTraceLoaded();
    await layout.waitForAllComponentsLoaded();

    await retry(
      async () => (await getSessionCount(ctPage)) >= 1,
      { maxAttempts: 30, delayMs: 1000 },
    );
    expect(await sessionHasTrace(ctPage, 0)).toBe(true);

    const trace0 = await getSessionTrace(ctPage, 0);
    expect(trace0).not.toBeNull();
    console.log(`# session 0 (materialized Python): id=${trace0!.id} program=${trace0!.program}`);

    // ==================================================================
    // Phase 2: Pre-record the Noir and C traces
    // ==================================================================

    const noirProgramPath = path.join(testProgramsPath, "noir_example") + "/";
    const noirTraceId = recordTestProgram(noirProgramPath);
    console.log(`# pre-recorded Noir trace: id=${noirTraceId}`);

    const cProgramPath = path.join(testProgramsPath, "c_sudoku_solver", "main.c");
    const cTraceId = recordTestProgram(cProgramPath);
    console.log(`# pre-recorded C/RR trace: id=${cTraceId}`);

    // ==================================================================
    // Phase 3: Session 1 — Noir trace (materialized, DB-based)
    // ==================================================================

    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 2,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(1);

    await loadTraceIntoActiveSession(ctPage, noirTraceId);
    await retry(
      async () => await sessionHasTrace(ctPage, 1),
      { maxAttempts: 60, delayMs: 1000 },
    );

    const trace1 = await getSessionTrace(ctPage, 1);
    expect(trace1).not.toBeNull();
    expect(trace1!.id).toBe(noirTraceId);
    console.log(`# session 1 (Noir): id=${trace1!.id} program=${trace1!.program}`);

    // ==================================================================
    // Phase 4: Session 2 — C/RR trace
    // ==================================================================

    await ctPage.locator(".session-tab-add").click();
    await retry(
      async () => (await getSessionCount(ctPage)) === 3,
      { maxAttempts: 20, delayMs: 500 },
    );
    expect(await getActiveIndex(ctPage)).toBe(2);

    await loadTraceIntoActiveSession(ctPage, cTraceId);
    await retry(
      async () => await sessionHasTrace(ctPage, 2),
      { maxAttempts: 60, delayMs: 1000 },
    );

    const trace2 = await getSessionTrace(ctPage, 2);
    expect(trace2).not.toBeNull();
    expect(trace2!.id).toBe(cTraceId);
    console.log(`# session 2 (C/RR): id=${trace2!.id} program=${trace2!.program}`);

    // ==================================================================
    // Phase 5: Verify all three traces are distinct
    // ==================================================================

    const ids = new Set([trace0!.id, trace1!.id, trace2!.id]);
    expect(ids.size).toBe(3);

    // ==================================================================
    // Phase 6: Verify trace metadata preserved after switching
    // ==================================================================

    // All three sessions should still have their traces in the data model.
    const verifySession = async (idx: number, expectedId: number) => {
      const trace = await getSessionTrace(ctPage, idx);
      expect(trace, `session ${idx} should still have its trace`).not.toBeNull();
      expect(trace!.id, `session ${idx} trace ID should match`).toBe(expectedId);
    };

    await verifySession(0, trace0!.id);
    await verifySession(1, noirTraceId);
    await verifySession(2, cTraceId);

    // Switch to session 1.
    const switchToSession = async (targetIdx: number) => {
      await ctPage.evaluate((idx) => {
        const d = (window as any).data;
        const fns = Object.getOwnPropertyNames(window).filter(
          (n) => n.startsWith("switchSession__"),
        );
        if (fns.length > 0) {
          (window as any)[fns[0]](d, idx);
        }
      }, targetIdx);
      await ctPage.waitForTimeout(1000);
    };

    await switchToSession(1);
    expect(await getActiveIndex(ctPage)).toBe(1);
    await verifySession(1, noirTraceId);

    // Switch to session 0.
    await switchToSession(0);
    expect(await getActiveIndex(ctPage)).toBe(0);
    await verifySession(0, trace0!.id);

    // Switch to session 2.
    await switchToSession(2);
    expect(await getActiveIndex(ctPage)).toBe(2);
    await verifySession(2, cTraceId);

    console.log("# three-trace-type test passed: materialized Python, Noir, and C/RR traces " +
      "loaded into separate sessions with correct isolation");
  });
});
