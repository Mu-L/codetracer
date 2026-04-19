/**
 * Playwright E2E test for cross-platform trace replay.
 *
 * Verifies that pre-recorded traces from `codetracer-example-recordings`
 * (which may have been recorded on a different platform/architecture) can be
 * loaded and displayed in the CodeTracer browser UI via `ct host --trace-path`.
 *
 * Each platform fixture (android-arm64, ios-arm64, linux-x86_64, macos-arm64,
 * windows-x86_64) gets its own test case. The test copies the `.ct` file into
 * a temporary trace folder with the required metadata files, then launches
 * `ct host --trace-path <folder>` — no SQLite database manipulation needed.
 *
 * Skips gracefully when the example-recordings sibling repo is not present.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as childProcess from "node:child_process";
import * as process from "node:process";

import { test as base, expect } from "@playwright/test";
import { chromium } from "playwright";

import { getFreeTcpPort } from "../lib/port-allocator";

// ---------------------------------------------------------------------------
// Path constants
// ---------------------------------------------------------------------------

const currentDir = path.resolve();
const codetracerInstallDir = path.dirname(currentDir);

const codetracerPrefix = path.join(codetracerInstallDir, "src", "build-debug");
const ctBinaryName = process.platform === "win32" ? "ct.exe" : "ct";
const envCodetracerPath = process.env.CODETRACER_E2E_CT_PATH ?? "";
const codetracerPath =
  envCodetracerPath.length > 0
    ? envCodetracerPath
    : path.join(codetracerPrefix, "bin", ctBinaryName);

// The example-recordings repo sits as a sibling of codetracer/ inside the
// workspace root. Walk up from the codetracer install dir to find it.
const workspaceRoot = path.dirname(codetracerInstallDir);
const exampleRecordingsDir = path.join(
  workspaceRoot,
  "codetracer-example-recordings",
);

const MCR_DIR = path.join(exampleRecordingsDir, "mcr");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const MAX_CONNECT_ATTEMPTS = 25;
const RETRY_DELAY_MS = 1_500;
const GOTO_TIMEOUT_MS = 5_000;
const PORT_RELEASE_DELAY_MS = 500;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Recursively kills a process and all its descendants.
 */
function killProcessTree(pid: number): void {
  if (process.platform === "win32") {
    try {
      childProcess.execSync(`taskkill /PID ${pid} /T /F`, {
        encoding: "utf-8",
        stdio: "pipe",
        windowsHide: true,
      });
    } catch {
      // Process may already be dead.
    }
    return;
  }

  let childPids: number[] = [];
  try {
    const output = childProcess
      .execSync(`pgrep -P ${pid} 2>/dev/null`, { encoding: "utf-8" })
      .trim();
    if (output) {
      childPids = output.split("\n").map(Number).filter(Boolean);
    }
  } catch {
    // No children found.
  }

  for (const child of childPids) {
    killProcessTree(child);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // Already dead.
  }
}

/**
 * Resolves the chromium executable path from $PLAYWRIGHT_BROWSERS_PATH.
 */
function resolveChromiumPath(): string {
  const browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH;
  if (!browsersDir) {
    throw new Error(
      "expected $PLAYWRIGHT_BROWSERS_PATH env var to be set: can't find browser without it",
    );
  }
  const chromiumDir = fs
    .readdirSync(browsersDir)
    .filter(
      (d: string) => d.startsWith("chromium-") && !d.includes("headless"),
    )
    .sort()
    .pop();
  if (!chromiumDir) {
    throw new Error(`no chromium-* directory found in ${browsersDir}`);
  }

  const chromiumBase = path.join(browsersDir, chromiumDir);

  if (process.platform === "win32") {
    const chromeSubdir = fs
      .readdirSync(chromiumBase)
      .find((d: string) => d.startsWith("chrome-win"));
    if (!chromeSubdir) {
      throw new Error(`no chrome-win* directory found in ${chromiumBase}`);
    }
    return path.join(chromiumBase, chromeSubdir, "chrome.exe");
  }

  const chromeSubdir = fs
    .readdirSync(chromiumBase)
    .find((d: string) => d.startsWith("chrome-linux"));
  if (!chromeSubdir) {
    throw new Error(`no chrome-linux* directory found in ${chromiumBase}`);
  }
  return path.join(chromiumBase, chromeSubdir, "chrome");
}

/**
 * Creates a clean environment for launching CodeTracer processes,
 * free of leftover trace-related variables.
 */
function makeCleanEnv(
  extra?: Record<string, string>,
): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (v !== undefined) env[k] = v;
  }
  delete env.CODETRACER_TRACE_ID;
  delete env.CODETRACER_CALLER_PID;
  delete env.CODETRACER_PREFIX;
  env.CODETRACER_IN_UI_TEST = "1";
  env.CODETRACER_TEST = "1";
  if (extra) {
    Object.assign(env, extra);
  }
  return env;
}

/**
 * Prepares a temporary trace folder from a platform fixture directory.
 *
 * Copies the `.ct` trace file and creates the minimal metadata files
 * (`trace_db_metadata.json`, `trace_paths.json`) required by `ct host
 * --trace-path`. Also copies the source file into `files/` if available
 * so the editor panel can display it.
 */
function prepareTraceFolder(platformDir: string): string {
  const tmpDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "ct-cross-platform-test-"),
  );

  // Copy the .ct trace file.
  const traceFile = path.join(platformDir, "trace.ct");
  fs.copyFileSync(traceFile, path.join(tmpDir, "trace.ct"));

  // Create minimal metadata for the trace.
  fs.writeFileSync(
    path.join(tmpDir, "trace_db_metadata.json"),
    JSON.stringify({
      program: "ct_fixture_prog",
      args: [],
      workdir: tmpDir,
      lang: "c",
    }),
  );
  fs.writeFileSync(path.join(tmpDir, "trace_paths.json"), "[]");

  // Copy the source file into files/ so the editor can display it.
  // The fixture directories contain a `source.c` symlink pointing to the
  // shared program in the example-recordings repo.
  const sourceFile = path.join(platformDir, "source.c");
  if (fs.existsSync(sourceFile)) {
    const filesDir = path.join(tmpDir, "files");
    fs.mkdirSync(filesDir, { recursive: true });
    // Resolve the symlink to get the actual file content.
    fs.copyFileSync(fs.realpathSync(sourceFile), path.join(filesDir, "source.c"));
  }

  return tmpDir;
}

// ---------------------------------------------------------------------------
// Discover available platform fixtures
// ---------------------------------------------------------------------------

const platforms: string[] = (() => {
  if (!fs.existsSync(MCR_DIR)) return [];
  return fs
    .readdirSync(MCR_DIR)
    .filter((d) => {
      const traceFile = path.join(MCR_DIR, d, "trace.ct");
      return fs.existsSync(traceFile);
    })
    .sort();
})();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Use a longer timeout: the backend needs to parse a trace that may have been
// produced on a different platform.
base.setTimeout(120_000);

base.describe("cross-platform trace replay", () => {
  // Each test spawns ct host on its own ports, but run serially to avoid
  // resource contention.
  base.describe.configure({ mode: "serial" });

  base.skip(
    platforms.length === 0,
    `Skipped: no platform fixtures found (expected at ${MCR_DIR})`,
  );

  for (const platform of platforms) {
    base(`${platform} trace loads in browser`, async () => {
      const platformDir = path.join(MCR_DIR, platform);
      const traceFolder = prepareTraceFolder(platformDir);
      let ctProcess: childProcess.ChildProcess | null = null;
      let browser: Awaited<ReturnType<typeof chromium.launch>> | null = null;

      try {
        // -- Launch ct host with --trace-path --------------------------------
        const httpPort = await getFreeTcpPort();
        const backendPort = await getFreeTcpPort();

        // Set up LD_LIBRARY_PATH if configured (needed on Linux for native
        // shared libraries).
        if (process.env.CT_LD_LIBRARY_PATH) {
          process.env.LD_LIBRARY_PATH = process.env.CT_LD_LIBRARY_PATH;
        }

        console.log(
          `# cross-platform test [${platform}]: launching ct host ` +
            `--trace-path ${traceFolder} on port ${httpPort}`,
        );

        ctProcess = childProcess.spawn(
          codetracerPath,
          [
            "host",
            "--trace-path", traceFolder,
            `--port=${httpPort}`,
            `--backend-socket-port=${backendPort}`,
            `--frontend-socket=${backendPort}`,
          ],
          {
            cwd: codetracerInstallDir,
            env: makeCleanEnv(),
            stdio: ["ignore", "pipe", "pipe"],
            windowsHide: true,
          },
        );

        // Capture stdout/stderr for diagnostics on failure.
        const ctStdout: string[] = [];
        const ctStderr: string[] = [];
        ctProcess.stdout?.on("data", (chunk: Buffer) => {
          ctStdout.push(chunk.toString());
        });
        ctProcess.stderr?.on("data", (chunk: Buffer) => {
          ctStderr.push(chunk.toString());
        });

        // -- Launch browser and connect to ct host ----------------------------
        const chromiumPath = resolveChromiumPath();
        const extraArgs = (process.env.CODETRACER_ELECTRON_ARGS ?? "")
          .split(/\s+/)
          .filter(Boolean);
        browser = await chromium.launch({
          executablePath: chromiumPath,
          args: extraArgs,
        });

        const page = await browser.newPage();

        // Retry connecting until ct host is ready.
        let connected = false;
        for (
          let attempt = 1;
          attempt <= MAX_CONNECT_ATTEMPTS && !connected;
          attempt++
        ) {
          try {
            await page.goto(`http://localhost:${httpPort}`, {
              timeout: GOTO_TIMEOUT_MS,
            });
            connected = true;
          } catch {
            if (attempt < MAX_CONNECT_ATTEMPTS) {
              console.log(
                `  ct host connect attempt ${attempt}/${MAX_CONNECT_ATTEMPTS} failed, retrying...`,
              );
              await sleep(RETRY_DELAY_MS);
            }
          }
        }

        if (!connected) {
          console.error(`ct host stdout:\n${ctStdout.join("")}`);
          console.error(`ct host stderr:\n${ctStderr.join("")}`);
          throw new Error(
            `Failed to connect to ct host on port ${httpPort} ` +
              `after ${MAX_CONNECT_ATTEMPTS} attempts [${platform}]`,
          );
        }

        console.log(`# ct host connected for ${platform}, verifying GUI...`);

        // -- Assertions: verify the GUI loaded correctly ----------------------

        // 1. Page title should contain "CodeTracer" (set by the frontend).
        await expect(async () => {
          const title = await page.title();
          expect(title.toLowerCase()).toContain("codetracer");
        }).toPass({ timeout: 30_000, intervals: [1_000] });

        // 2. The status bar (bottom bar with location info) should be visible.
        //    This indicates the layout has loaded and the backend has connected.
        const statusBar = page.locator(
          ".status-bar, .bottom-bar, .location-path",
        );
        await expect(statusBar.first()).toBeVisible({ timeout: 30_000 });

        // 3. At least one golden-layout component should be present, indicating
        //    the main UI panels (editor, event log, etc.) have rendered.
        const glComponent = page.locator(".lm_item");
        await expect(glComponent.first()).toBeVisible({ timeout: 30_000 });

        // 4. Check that some content has loaded by verifying the page body is
        //    not empty or stuck on a loading screen.
        const bodyText = await page.evaluate(
          () => document.body?.innerText ?? "",
        );
        expect(bodyText.length).toBeGreaterThan(0);

        console.log(`# cross-platform replay test passed for ${platform}`);
      } finally {
        // -- Cleanup ----------------------------------------------------------
        if (ctProcess?.pid) {
          killProcessTree(ctProcess.pid);
        }
        await sleep(PORT_RELEASE_DELAY_MS);

        if (browser) {
          try {
            await browser.close();
          } catch {
            // Already closed.
          }
        }

        // Remove the temporary trace folder.
        try {
          fs.rmSync(traceFolder, { recursive: true, force: true });
        } catch {
          // Best-effort cleanup.
        }

        // Clean up env vars that ct host may have set.
        delete process.env.CODETRACER_TRACE_ID;
        delete process.env.CODETRACER_CALLER_PID;
        delete process.env.CODETRACER_IN_UI_TEST;
        delete process.env.CODETRACER_TEST;
      }
    });
  }
});
