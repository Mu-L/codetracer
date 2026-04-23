import * as fs from "node:fs";
import { defineConfig } from "@playwright/test";

/**
 * Resolve the Chromium executable for Playwright's browser fixtures.
 *
 * Priority:
 *   1. PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH env var (explicit override)
 *   2. PLAYWRIGHT_BROWSERS_PATH env var (Playwright's own bundled browser dir)
 *   3. System chromium at /run/current-system/sw/bin/chromium (NixOS)
 *   4. undefined — let Playwright use its default discovery
 */
function resolveChromiumExecutable(): string | undefined {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
    return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
  }
  // If Playwright's bundled browsers are configured, let it handle discovery.
  if (process.env.PLAYWRIGHT_BROWSERS_PATH) {
    return undefined;
  }
  // NixOS / nix-managed system: use the system chromium.
  const nixChromium = "/run/current-system/sw/bin/chromium";
  if (fs.existsSync(nixChromium)) {
    return nixChromium;
  }
  return undefined;
}

const chromiumExecutable = resolveChromiumExecutable();

export default defineConfig({
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: Number(process.env.PLAYWRIGHT_RETRIES ?? (process.env.CI ? 2 : 0)),
  workers: process.env.CI ? 1 : undefined,
  globalTimeout: Number(
    process.env.PLAYWRIGHT_GLOBAL_TIMEOUT ?? (process.env.CI ? 7_200_000 : 0),
  ),
  // Default timeout covers Electron launch (~20s) + simple UI interactions.
  // Tests involving trace recording override via test.setTimeout().
  timeout: 90_000,
  expect: { timeout: 30_000 },
  reporter: [
    [process.env.CI ? "github" : "list"],
    ["./lib/stats-reporter.ts"],
  ],
  use: {
    actionTimeout: 60_000,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    ...(chromiumExecutable && {
      launchOptions: { executablePath: chromiumExecutable },
    }),
  },
  // Deployment mode (electron vs web) is controlled per-test via
  // test.use({ deploymentMode: "web" }) or defaults to "electron".
  // To run all tests in web mode, set CODETRACER_TEST_IN_BROWSER=1.

  // Single project — the ctPage fixture auto-skips RR-based tests when
  // CODETRACER_RR_BACKEND_PRESENT is not set, using language detection
  // from lib/lang-support.ts. CI runs two jobs with different env vars;
  // locally, `just test-gui` runs everything.
  testDir: "./tests",
  // In the DB-only CI job, exclude per-language sudoku tests (they need
  // language-specific recorders not available in that job).
  ...(process.env.CODETRACER_DB_TESTS_ONLY === "1" && {
    testIgnore: "**/sudoku/**",
  }),
});
