/**
 * Playwright UI tests for the Miden/MASM example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders a Miden/MASM trace
 * correctly, covering:
 *   - Editor pane loading the .masm source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the MASM call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a MASM trace requires the Miden recorder pipeline:
 *   1. `codetracer-miden-recorder` binary available via
 *      `CODETRACER_MIDEN_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!midenPipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.masm` is integrated.
 *
 * The structural tests at the bottom run unconditionally and verify the
 * language-detection logic without launching Electron.
 */

import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";

// ---------------------------------------------------------------------------
// Tool-availability guards
// ---------------------------------------------------------------------------

/**
 * Returns true when the `codetracer-miden-recorder` binary is reachable.
 * Checks `CODETRACER_MIDEN_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMidenRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MIDEN_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-miden-recorder";
  try {
    const result = childProcess.spawnSync(binary, ["--version"], {
      encoding: "utf-8",
      timeout: 5_000,
    });
    return result.status === 0;
  } catch {
    return false;
  }
}

// Evaluated at collection time so skip decisions are instant.
const midenRecorderAvailable = hasMidenRecorder();
const midenPipelineAvailable = midenRecorderAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("masm_example — basic layout", () => {
  // Skip the entire suite when the Miden recorder pipeline is absent.
  // Remove this guard once `ct record <path>.masm` is integrated.
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  test("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    // In browser mode the title includes the trace name, so use toContain.
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  test("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const location = await statusBar.location();
    // The entry point should resolve to the MASM source file.
    expect(location.path.endsWith("compute.masm")).toBeTruthy();
    // The MASM trace starts at the begin block; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("masm_example — event log", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  test("event log has at least one event", async ({ ctPage }) => {
    // Wait for the event log footer row-count to appear.
    await loadedEventLog(ctPage);

    const raw = await ctPage.$eval(
      ".data-tables-footer-rows-count",
      (el) => el.textContent ?? "",
    );
    const match = raw.match(/(\d+)/);
    expect(match).not.toBeNull();
    const count = parseInt(match![1], 10);
    expect(count).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: state panel
// ---------------------------------------------------------------------------

test.describe("masm_example — state panel", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // Stack/local variable decoding via the Miden VM state is not yet
  // plumbed through the db-backend DAP session for MASM traces.
  // Re-enable once the Miden stack decoder is integrated.
  test.fixme("state panel shows decoded stack/local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    // After compute completes: loc_store.4 holds final_result = 94.
    expect(values.loc_4.text).toBe("94");
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("masm_example — call trace", () => {
  test.skip(
    !midenPipelineAvailable,
    "Miden recorder pipeline not available (need codetracer-miden-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "masm_example/compute.masm", launchMode: "trace" });

  // The db-backend does not yet emit DAP calltrace entries for MASM traces.
  // Re-enable once the backend exposes Miden call frames.
  test.fixme("call trace shows compute procedure entry", async () => {
    // Requires calltrace DAP support for Miden/MASM traces.
  });

  test.fixme("continue", async () => {
    // Requires debug movement counter support for Miden/MASM backend.
  });

  test.fixme("next", async () => {
    // Requires debug movement counter support for Miden/MASM backend.
  });
});

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("masm_example — environment detection", () => {
  test("masm extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .masm files as DB-based
    // so they don't attempt RR recording when midenPipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("compute.masm")).toBe(true);
    expect(isDbBased("some/path/program.masm")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof midenRecorderAvailable).toBe("boolean");
    expect(typeof midenPipelineAvailable).toBe("boolean");
  });
});
