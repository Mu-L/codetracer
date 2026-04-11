import { test, expect, readyOnEntryTest as readyOnEntry, loadedEventLog } from "../../lib/fixtures";
import { StatusBar } from "../../page-objects/status_bar";
import { StatePanel } from "../../page-objects/state";
import { retry } from "../../lib/retry-helpers";

const ENTRY_LINE = 11;

// Each describe block gets its own fixture scope (each test records + launches independently).

test.describe("wasm example — basic layout", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "wasm_example/", launchMode: "trace" });

  // TODO(skipped): ct record for WASM requires `cargo build --target wasm32-wasip1` which is not
  //   available in the nix-built ct wrapper's PATH. The WASM build toolchain is missing.
  //   Hypothesis: Add wasm32-wasip1 target to the codetracer nix dev shell, or pre-build
  //   the WASM binary and use it as a fixture.
  test.fixme("we can access the browser window, not just dev tools", async ({ ctPage }) => {
    const title = await ctPage.title();
    expect(title).toContain("CodeTracer");
    await ctPage.focus("div");
  });

  // TODO(skipped): WASM backend does not send CtCompleteMove on trace load, so .location-path
  //   never appears and readyOnEntry() times out.
  //   Hypothesis: The wazero-based WASM db-backend needs to emit CtCompleteMove after initial
  //   trace load so the frontend can populate the status bar location.
  test.fixme("correct entry status path/line", async ({ ctPage }) => {
    await readyOnEntry(ctPage);

    const statusBar = new StatusBar(ctPage, ctPage.locator("#status-base"));
    const simpleLocation = await statusBar.location();
    expect(simpleLocation.path.endsWith("main.rs")).toBeTruthy();
    expect(simpleLocation.line).toBe(ENTRY_LINE);
  });
});

test.describe("wasm example — state and navigation", () => {
  test.setTimeout(90_000);
  test.use({ sourcePath: "wasm_example/", launchMode: "trace" });

  // TODO(skipped): Event log footer row count is not populated for WASM/DB traces.
  //   The `.data-tables-footer-rows-count` element shows 0 or is missing.
  //   Hypothesis: The frontend event count population code path is only wired for RR-based
  //   traces. The DB trace loader needs to emit the event count to the frontend.
  test.fixme("expected event count", async ({ ctPage }) => {
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

  // TODO(skipped): WASM backend does not send CtCompleteMove on trace load, so readyOnEntry
  //   times out waiting for the status bar to show a location.
  //   Hypothesis: Same as "correct entry status path/line" -- needs CtCompleteMove in wazero backend.
  test.fixme("state panel loaded initially", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);
    // Wait for the code state line to be populated before asserting
    await retry(
      async () => {
        const text = await statePanel.codeStateLine().textContent();
        return text !== null && text.includes(`${ENTRY_LINE} | `);
      },
      { maxAttempts: 20, delayMs: 300 },
    );
    await expect(statePanel.codeStateLine()).toContainText(`${ENTRY_LINE} | `);
  });

  // TODO(skipped): WASM DB-based debugger variable inspection is not supported in the wazero backend.
  //   Variables x, y are expected but the state panel is empty.
  //   Hypothesis: The wazero trace format does not include DWARF-level variable data.
  //   Needs wazero to emit local variable values in its trace output.
  test.fixme("state panel supports integer values", async ({ ctPage }) => {
    await readyOnEntry(ctPage);
    const statePanel = new StatePanel(ctPage);

    const values = await statePanel.values();
    expect(values.x.text).toBe("3");
    expect(values.x.typeText).toBe("i32");

    expect(values.y.text).toBe("4");
    expect(values.y.typeText).toBe("i32");
  });

  // TODO(skipped): Debug movement (continue/next) not implemented for WASM traces.
  //   The wazero backend does not emit movement counters or CtCompleteMove events.
  //   Hypothesis: Needs debug movement support in the WASM db-backend, similar to noir.
  test.fixme("continue", async () => {
    // Requires debug movement counter support in WASM backend.
  });

  // TODO(skipped): Same as "continue" above -- debug movement not implemented for WASM traces.
  //   Hypothesis: Needs debug movement support in the WASM db-backend.
  test.fixme("next", async () => {
    // Requires debug movement counter support in WASM backend.
  });
});
