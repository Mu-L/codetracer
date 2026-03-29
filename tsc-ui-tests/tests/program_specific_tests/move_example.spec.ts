/**
 * Playwright UI tests for the Move example (M7: Playwright UI Tests).
 *
 * These tests verify that the CodeTracer UI renders a Move trace
 * correctly, covering:
 *   - Editor pane loading the .move source file
 *   - Status bar showing the correct source location after trace load
 *   - Event log populated with at least one event
 *   - Call trace pane showing the Move call tree
 *   - Variable state pane available after navigating to a call frame
 *
 * ## Prerequisites
 *
 * Recording a Move trace requires the Move recorder pipeline:
 *   1. `codetracer-move-recorder` binary available via
 *      `CODETRACER_MOVE_RECORDER_PATH` or on PATH.
 *
 * Because this pipeline is not yet wired into `ct record`, all tests that
 * require a live trace are guarded by `test.skip(!movePipelineAvailable, ...)`.
 * They will run automatically once `ct record <path>.move` is integrated.
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
 * Returns true when the `codetracer-move-recorder` binary is reachable.
 * Checks `CODETRACER_MOVE_RECORDER_PATH` env var first, then falls back to PATH.
 */
function hasMoveRecorder(): boolean {
  const fromEnv = process.env.CODETRACER_MOVE_RECORDER_PATH ?? "";
  const binary = fromEnv.length > 0 ? fromEnv : "codetracer-move-recorder";
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
const moveRecorderAvailable = hasMoveRecorder();
const movePipelineAvailable = moveRecorderAvailable;

// ---------------------------------------------------------------------------
// Test suite: basic layout (title, entry status)
// ---------------------------------------------------------------------------

test.describe("move_example — basic layout", () => {
  // Skip the entire suite when the Move recorder pipeline is absent.
  // Remove this guard once `ct record <path>.move` is integrated.
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

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
    // The entry point should resolve to the Move source file.
    expect(location.path.endsWith("flow_test.move")).toBeTruthy();
    // The Move trace starts inside test_computation; any valid source line > 0 is acceptable.
    expect(location.line).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Test suite: event log
// ---------------------------------------------------------------------------

test.describe("move_example — event log", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

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

test.describe("move_example — state panel", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  test("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statePanel = new StatePanel(ctPage);
    // The code-state line must contain a line number followed by " | ".
    await expect(statePanel.codeStateLine()).toContainText(" | ");
  });

  // Variable decoding via the Move VM bytecode state is not yet
  // plumbed through the db-backend DAP session for Move traces.
  // Re-enable once the Move variable decoder is integrated.
  test.fixme("state panel shows decoded local variables", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    const values = await statePanel.values();
    // After test_computation completes: a=10, b=32, sum_val=42, doubled=84, final_result=94.
    expect(values.final_result.text).toBe("94");
  });
});

// ---------------------------------------------------------------------------
// Test suite: call trace pane
// ---------------------------------------------------------------------------

test.describe("move_example — call trace", () => {
  test.skip(
    !movePipelineAvailable,
    "Move recorder pipeline not available (need codetracer-move-recorder)",
  );

  test.setTimeout(90_000);
  test.use({ sourcePath: "move_example/sources/flow_test.move", launchMode: "trace" });

  // The db-backend does not yet emit DAP calltrace entries for Move traces.
  // Re-enable once the backend exposes Move call frames.
  test.fixme("call trace shows test_computation entry", async () => {
    // Requires calltrace DAP support for Move traces.
  });

  test.fixme("continue", async () => {
    // Requires debug movement counter support for Move backend.
  });

  test.fixme("next", async () => {
    // Requires debug movement counter support for Move backend.
  });
});

// ---------------------------------------------------------------------------
// Structural tests — run unconditionally, no Electron launch needed
// ---------------------------------------------------------------------------

test.describe("move_example — environment detection", () => {
  test("move extension is classified as DB-based (no RR required)", () => {
    // Validate that lang-support.ts correctly marks .move files as DB-based
    // so they don't attempt RR recording when movePipelineAvailable is true.
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { isDbBased } = require("../../lib/lang-support");
    expect(isDbBased("flow_test.move")).toBe(true);
    expect(isDbBased("some/path/module.move")).toBe(true);
    // Sanity-check: other DB-based languages must remain unaffected.
    expect(isDbBased("main.py")).toBe(true);
    // Sanity-check: RR-based languages must remain unaffected.
    expect(isDbBased("main.rs")).toBe(false);
  });

  test("tool availability detection does not throw", () => {
    // These checks must succeed (or gracefully return false) even when the
    // tools are absent; no exception should propagate.
    expect(typeof moveRecorderAvailable).toBe("boolean");
    expect(typeof movePipelineAvailable).toBe("boolean");
  });
});
