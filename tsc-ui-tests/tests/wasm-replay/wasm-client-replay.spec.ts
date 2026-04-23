/**
 * Playwright E2E test for TRUE client-side WASM replay.
 *
 * Architecture:
 *   - Server: dumb HTTP file server (Node http module) serving static files.
 *     No WebSocket, no custom endpoints, no server-side logic.
 *   - Browser: loads the WASM db-backend in a WebWorker, fetches trace files
 *     via fetch(), pushes them into the VFS, and runs the full DAP protocol
 *     entirely client-side.
 *
 * This test uses a pre-recorded Noir "array" trace from the db-backend
 * test-traces directory as a fixture — no recording happens during the test.
 */

import { test, expect, type Page } from "@playwright/test";
import * as http from "node:http";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");
const WASM_TESTING_DIR = path.join(REPO_ROOT, "src", "db-backend", "wasm-testing");
const TEST_TRACES_DIR = path.join(
  REPO_ROOT,
  "src",
  "db-backend",
  "test-traces",
  "pid-2876854",
  "array",
  "noir",
);

// Trace files that make up the fixture.
const TRACE_FILES = ["trace.json", "trace_metadata.json", "trace_paths.json"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Find a free TCP port. */
function getFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      if (addr && typeof addr === "object") {
        const port = addr.port;
        srv.close(() => resolve(port));
      } else {
        srv.close(() => reject(new Error("Could not determine port")));
      }
    });
    srv.on("error", reject);
  });
}

/**
 * Start a minimal static HTTP file server.
 *
 * Serves:
 *   /               — wasm-testing directory (HTML, JS, WASM, pkg/)
 *   /traces/<file>  — trace fixture files
 *
 * Returns the server instance and the base URL.
 */
async function startStaticServer(): Promise<{
  server: http.Server;
  baseUrl: string;
}> {
  const port = await getFreePort();

  const MIME: Record<string, string> = {
    ".html": "text/html",
    ".js": "application/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".css": "text/css",
    ".ts": "text/plain",
  };

  const server = http.createServer((req, res) => {
    const url = new URL(req.url || "/", `http://localhost:${port}`);
    let filePath: string;

    if (url.pathname.startsWith("/traces/")) {
      // Serve from the test-traces fixture directory.
      // Use basename to prevent path traversal.
      const fileName = path.basename(url.pathname);
      filePath = path.join(TEST_TRACES_DIR, fileName);
    } else {
      // Serve from wasm-testing directory.
      // Strip leading slash; default to replay-test.html.
      const relPath = url.pathname.slice(1) || "replay-test.html";
      filePath = path.resolve(WASM_TESTING_DIR, relPath);
      // Prevent path traversal outside wasm-testing.
      if (!filePath.startsWith(WASM_TESTING_DIR)) {
        res.writeHead(403, { "Content-Type": "text/plain" });
        res.end("Forbidden");
        return;
      }
    }

    if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      res.writeHead(404, { "Content-Type": "text/plain" });
      res.end("Not found");
      return;
    }

    const ext = path.extname(filePath);
    const contentType = MIME[ext] || "application/octet-stream";

    // Serve the file with appropriate headers. All responses include
    // CORS and CORP headers so the page works under cross-origin isolation
    // if needed in the future (e.g. for SharedArrayBuffer / WASM threads).
    const headers: Record<string, string> = {
      "Content-Type": contentType,
      "Access-Control-Allow-Origin": "*",
      "Cross-Origin-Resource-Policy": "same-origin",
    };

    const body = fs.readFileSync(filePath);
    res.writeHead(200, headers);
    res.end(body);
  });

  return new Promise((resolve, reject) => {
    server.listen(port, "127.0.0.1", () => {
      resolve({ server, baseUrl: `http://127.0.0.1:${port}` });
    });
    server.on("error", reject);
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("WASM client-side replay", () => {
  let server: http.Server;
  let baseUrl: string;

  // Increase timeout — WASM compilation can be slow on first load.
  test.setTimeout(120_000);

  test.beforeAll(async () => {
    // Verify that the WASM pkg exists (must be pre-built).
    const wasmPkg = path.join(WASM_TESTING_DIR, "pkg", "db_backend.js");
    if (!fs.existsSync(wasmPkg)) {
      throw new Error(
        `WASM package not found at ${wasmPkg}. ` +
          `Run "cd src/db-backend && bash build_wasm.sh" first.`,
      );
    }

    // Verify that the trace fixture files exist.
    for (const f of TRACE_FILES) {
      const fp = path.join(TEST_TRACES_DIR, f);
      if (!fs.existsSync(fp)) {
        throw new Error(`Trace fixture file not found: ${fp}`);
      }
    }

    const result = await startStaticServer();
    server = result.server;
    baseUrl = result.baseUrl;
  });

  test.afterAll(async () => {
    if (server) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });

  test("loads trace entirely in browser via WASM — no server logic", async ({
    page,
  }) => {
    // Collect console messages for debugging.
    const consoleLogs: string[] = [];
    page.on("console", (msg) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
    page.on("pageerror", (err) => consoleLogs.push(`[pageerror] ${err.message}`));

    // Navigate to the test page. The replay-test.js script will:
    //   1. Create the WebWorker
    //   2. Wait for WASM to load
    //   3. Tell the worker to fetch trace files from /traces/
    //   4. Start the DAP server
    //   5. Send DAP initialize + launch + configurationDone
    //   6. Set window.__replayTestResult
    const traceFiles = TRACE_FILES.join(",");
    const url = `${baseUrl}/replay-test.html?traceFolder=trace&files=${traceFiles}`;
    await page.goto(url);

    // Wait for the test to complete (success or failure).
    await page.waitForFunction(
      () => (window as any).__replayTestResult !== undefined,
      { timeout: 60_000 },
    );

    const result = await page.evaluate(() => (window as any).__replayTestResult);

    // Log all console output for debugging on failure.
    if (!result.success) {
      console.log("=== Browser console logs ===");
      for (const line of consoleLogs) {
        console.log(line);
      }
      console.log("=== End browser logs ===");
    }

    // Assert: the test succeeded.
    expect(result.success, `Replay failed: ${result.error}`).toBe(true);

    // Assert: DAP initialize returned a valid response.
    expect(result.initResponse).toBeDefined();
    expect(result.initResponse.command).toBe("initialize");
    expect(result.initResponse.success).toBe(true);

    // Assert: configurationDone succeeded (trace loaded from VFS).
    expect(result.configDoneResponse).toBeDefined();
    expect(result.configDoneResponse.command).toBe("configurationDone");
    expect(result.configDoneResponse.success).toBe(true);

    // Assert: we got DAP responses (at minimum: initialize response,
    // initialized event, launch response, configurationDone response).
    expect(result.totalResponses).toBeGreaterThanOrEqual(4);
  });

  test("status element shows success", async ({ page }) => {
    const traceFiles = TRACE_FILES.join(",");
    const url = `${baseUrl}/replay-test.html?traceFolder=trace&files=${traceFiles}`;
    await page.goto(url);

    // Wait for the status element to show a success state.
    await page.waitForFunction(
      () => {
        const el = document.getElementById("status");
        return el && el.classList.contains("ok");
      },
      { timeout: 60_000 },
    );

    const statusText = await page.textContent("#status");
    expect(statusText).toContain("trace loaded");
  });

  test("handles missing trace file gracefully", async ({ page }) => {
    const consoleLogs: string[] = [];
    page.on("console", (msg) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));

    // Request a non-existent trace file.
    const url = `${baseUrl}/replay-test.html?traceFolder=trace&files=nonexistent.json`;
    await page.goto(url);

    // Wait for the test to complete.
    await page.waitForFunction(
      () => (window as any).__replayTestResult !== undefined,
      { timeout: 30_000 },
    );

    const result = await page.evaluate(() => (window as any).__replayTestResult);

    // The test should report an error since the file does not exist.
    expect(result.success).toBe(false);
    expect(result.error).toContain("404");
  });
});
