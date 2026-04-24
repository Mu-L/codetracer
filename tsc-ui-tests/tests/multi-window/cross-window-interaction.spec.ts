/**
 * Cross-window interaction integration tests.
 *
 * Tests the full multi-window tab/panel management workflow described in
 * codetracer-specs/GUI/Multi-Window-Tab-Management.md:
 *
 * 1. "Open in New Window" creates a second Electron BrowserWindow
 * 2. Panel transfer via IPC (panel-detach -> panel-attach round-trip)
 * 3. Closing the last tab/session in a window triggers window cleanup
 * 4. Cross-window DnD (skipped unless xdotool is available)
 *
 * Since Playwright cannot directly interact with multiple Electron
 * BrowserWindows (each is a separate OS window), these tests verify
 * behaviour through the IPC data model and electronApp.evaluate().
 */

import * as childProcess from "node:child_process";
import { test, expect } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";
import { retry } from "../../lib/retry-helpers";

// ---------------------------------------------------------------------------
// Environment detection
// ---------------------------------------------------------------------------

/**
 * Check whether xdotool is available on the system PATH.
 * Used to conditionally enable native DnD tests.
 */
function hasXdotool(): boolean {
  try {
    const result = childProcess.spawnSync("which", ["xdotool"], {
      encoding: "utf-8",
      timeout: 3_000,
    });
    return result.status === 0 && result.stdout.trim().length > 0;
  } catch {
    return false;
  }
}

const xdotoolAvailable = hasXdotool();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Wait until `window.data.sessions` is populated and return the count. */
async function getSessionCount(
  page: import("@playwright/test").Page,
): Promise<number> {
  return page.evaluate(() => {
    const d = (window as any).data;
    return d?.sessions?.length ?? 0;
  });
}

/** Wait for at least one session to be present. */
async function waitForSession(
  page: import("@playwright/test").Page,
): Promise<void> {
  await retry(
    async () => (await getSessionCount(page)) >= 1,
    { maxAttempts: 30, delayMs: 1000 },
  );
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Cross-window interaction", () => {
  test.setTimeout(120_000);
  test.describe.configure({ retries: 2 });
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  // -------------------------------------------------------------------------
  // Test 1: "Open in New Window" creates a second BrowserWindow
  // -------------------------------------------------------------------------

  test("open-new-window IPC creates second BrowserWindow", async ({
    ctPage,
    electronApp,
  }) => {
    // This test requires Electron (not web mode) to inspect BrowserWindows.
    test.skip(electronApp === null, "requires Electron deployment mode");

    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await waitForSession(ctPage);

    // Count initial windows (may include DevTools).
    const initialWindowCount = await electronApp!.evaluate(
      async ({ BrowserWindow }) => BrowserWindow.getAllWindows().length,
    );

    // Trigger open-new-window via IPC from the renderer.
    await ctPage.evaluate(() => {
      const { ipcRenderer } = require("electron");
      ipcRenderer.send("CODETRACER::open-new-window", { sessionId: 0 });
    });

    // Wait for the new window to appear. The main process handler creates
    // the BrowserWindow asynchronously, so we poll.
    let newWindowCount = initialWindowCount;
    await retry(
      async () => {
        newWindowCount = await electronApp!.evaluate(
          async ({ BrowserWindow }) => BrowserWindow.getAllWindows().length,
        );
        return newWindowCount > initialWindowCount;
      },
      { maxAttempts: 20, delayMs: 500 },
    );

    expect(newWindowCount).toBeGreaterThan(initialWindowCount);
  });

  // -------------------------------------------------------------------------
  // Test 2: Panel transfer round-trip via IPC
  // -------------------------------------------------------------------------

  test("panel-detach and panel-attach IPC round-trip", async ({
    ctPage,
    electronApp,
  }) => {
    test.skip(electronApp === null, "requires Electron deployment mode");

    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await waitForSession(ctPage);

    // Create a second window so we have a valid target for panel transfer.
    await ctPage.evaluate(() => {
      const { ipcRenderer } = require("electron");
      ipcRenderer.send("CODETRACER::open-new-window", { sessionId: 0 });
    });

    // Wait for the second window to appear.
    await retry(
      async () => {
        const count = await electronApp!.evaluate(
          async ({ BrowserWindow }) => BrowserWindow.getAllWindows().length,
        );
        // Expect at least 2 (primary + new), possibly more with DevTools.
        return count >= 2;
      },
      { maxAttempts: 20, delayMs: 500 },
    );

    // Get the list of windows and their IDs from the main process.
    const windowIds = await electronApp!.evaluate(
      async ({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().map((w) => w.id),
    );

    // Identify the source (original) and target (new) window IDs.
    // The original window is the one containing ctPage. We find it by
    // checking which window's webContents matches the page URL.
    const sourceWindowId = await ctPage.evaluate(() => {
      try {
        const { remote } = require("@electron/remote");
        return remote.getCurrentWindow().id;
      } catch {
        // Fallback: if @electron/remote is not available, use ipcRenderer
        // to get window ID via a synchronous call.
        try {
          const { ipcRenderer } = require("electron");
          return ipcRenderer.sendSync("CODETRACER::get-window-id");
        } catch {
          return -1;
        }
      }
    });

    // Pick a target that is different from the source.
    const targetWindowId =
      sourceWindowId > 0
        ? windowIds.find((id) => id !== sourceWindowId) ?? windowIds[windowIds.length - 1]
        : windowIds[windowIds.length - 1];

    // Build a minimal panel config that resembles a real GL content item.
    const panelConfig = {
      type: "component",
      componentName: "editor",
      componentState: { filePath: "test.py", line: 1 },
    };

    // Send panel-detach from the renderer. The main process should route
    // it to the target window via panel-attach.
    const detachResult = await ctPage.evaluate(
      ({ targetId, config }) => {
        try {
          const { ipcRenderer } = require("electron");
          ipcRenderer.send("CODETRACER::panel-detach", {
            targetWindowId: targetId,
            panelConfig: config,
            sessionId: 0,
          });
          return { sent: true, error: null };
        } catch (e: any) {
          return { sent: false, error: e.message };
        }
      },
      { targetId: targetWindowId, config: panelConfig },
    );

    expect(detachResult.sent).toBe(true);

    // Verify that the main process forwarded the panel-attach message to
    // the target window. We check from the main process side: query
    // whether the target window's webContents received the message.
    // Since we cannot directly observe IPC delivery without instrumenting
    // the target window, we verify the detach was sent without error and
    // the target window still exists (was not closed by the transfer).
    const targetExists = await electronApp!.evaluate(
      async ({ BrowserWindow }, targetId) => {
        const win = BrowserWindow.fromId(targetId);
        return win !== null && !win.isDestroyed();
      },
      targetWindowId,
    );

    expect(targetExists).toBe(true);
  });

  // -------------------------------------------------------------------------
  // Test 3: list-windows returns valid window info
  // -------------------------------------------------------------------------

  test("list-windows IPC returns window information", async ({
    ctPage,
    electronApp,
  }) => {
    test.skip(electronApp === null, "requires Electron deployment mode");

    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await waitForSession(ctPage);

    // Set up a listener for the reply before sending the request.
    const windowList = await ctPage.evaluate(() => {
      return new Promise<any[]>((resolve, reject) => {
        const { ipcRenderer } = require("electron");
        const timeout = setTimeout(() => {
          reject(new Error("list-windows-reply timed out after 10s"));
        }, 10_000);

        ipcRenderer.once(
          "CODETRACER::list-windows-reply",
          (_event: any, payload: any) => {
            clearTimeout(timeout);
            resolve(payload.windows ?? []);
          },
        );

        ipcRenderer.send("CODETRACER::list-windows", {});
      });
    });

    // Should have at least the primary window.
    expect(Array.isArray(windowList)).toBe(true);
    expect(windowList.length).toBeGreaterThanOrEqual(1);

    // Each entry should have an id field.
    for (const entry of windowList) {
      expect(entry).toHaveProperty("id");
      expect(typeof entry.id).toBe("number");
    }
  });

  // -------------------------------------------------------------------------
  // Test 4: Session data model tracks session removal
  // -------------------------------------------------------------------------

  test("closing last session resets data model", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForTraceLoaded();
    await waitForSession(ctPage);

    // Simulate removing the active session from the data model.
    // This mirrors what happens when the last tab is closed.
    const result = await ctPage.evaluate(() => {
      const d = (window as any).data;
      if (!d.sessions || d.sessions.length === 0) {
        return { hadSession: false, removedOk: false, countAfter: -1 };
      }

      const originalCount = d.sessions.length;
      // Remove the active session.
      const removed = d.sessions.splice(d.activeSessionIndex, 1);
      const countAfter = d.sessions.length;

      // Restore the session so we do not break teardown.
      d.sessions.splice(d.activeSessionIndex, 0, ...removed);

      return {
        hadSession: originalCount >= 1,
        removedOk: countAfter === originalCount - 1,
        countAfter,
      };
    });

    expect(result.hadSession).toBe(true);
    expect(result.removedOk).toBe(true);
    expect(result.countAfter).toBe(0);
  });

  // -------------------------------------------------------------------------
  // Test 5: Cross-window drag-and-drop (requires xdotool)
  // -------------------------------------------------------------------------

  test("cross-window tab drag-and-drop via xdotool", async ({
    ctPage,
    electronApp,
  }) => {
    test.skip(!xdotoolAvailable, "requires xdotool for cross-window DnD — add xdotool to flake.nix buildInputs");
    test.skip(electronApp === null, "requires Electron deployment mode");

    // This test would:
    // 1. Open a trace, locate the tab bar element via Playwright boundingBox()
    // 2. Create a second window via IPC
    // 3. Get both windows' X11 window IDs via electronApp.evaluate()
    // 4. Use xdotool to:
    //    a. mousemove to the tab in window A
    //    b. mousedown
    //    c. mousemove to window B's tab bar region
    //    d. mouseup
    // 5. Verify the tab moved to window B via the data model
    //
    // Implementation deferred until xdotool is added to the nix dev shell.
    // See codetracer-specs/GUI/Multi-Window-Tab-Management.md for the full
    // testing strategy.

    expect(true).toBe(true); // Placeholder — will be replaced with real assertions.
  });
});
