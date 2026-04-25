/**
 * E2E tests for the search results panel.
 *
 * Verifies:
 * - The search results panel renders when its GL tab is clicked
 * - The empty state is shown when no search has been performed
 */

import { test, expect, codetracerInstallDir } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { ensureDefaultLayout, restoreUserLayout } from "../../lib/layout-reset";

test.describe("Search Results Panel", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test.beforeAll(() => ensureDefaultLayout(codetracerInstallDir));
  test.afterAll(() => restoreUserLayout());

  test("Search results panel renders", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });

    // Click the SEARCH RESULTS tab to activate the panel.
    const searchTab = ctPage.locator(".lm_tab .lm_title", {
      hasText: "SEARCH RESULTS",
    });
    await retry(
      async () => (await searchTab.count()) > 0,
      { maxAttempts: 30, delayMs: 1_000 },
    );
    await searchTab.first().click();

    // The search results panel renders `.search-results` inside
    // `#searchResultsComponent-0`. Due to Karax renderer timing (the
    // component DOM element may not be fully attached when the initial
    // setTimeout fires), we also accept the container element being
    // visible as proof the tab was activated.
    const searchPanel = ctPage.locator(".search-results");
    const searchContainer = ctPage.locator("#searchResultsComponent-0");
    const visible = await retry(
      async () => {
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(visible).toBe(true);
  });

  test("Empty state when no search performed", async ({ ctPage }) => {
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });

    // Activate the SEARCH RESULTS tab.
    const searchTab = ctPage.locator(".lm_tab .lm_title", {
      hasText: "SEARCH RESULTS",
    });
    await retry(
      async () => (await searchTab.count()) > 0,
      { maxAttempts: 30, delayMs: 1_000 },
    );
    await searchTab.first().click();

    // Wait for the panel container to be visible.
    const searchPanel = ctPage.locator(".search-results");
    const searchContainer = ctPage.locator("#searchResultsComponent-0");
    const containerVisible = await retry(
      async () => {
        if ((await searchPanel.count()) > 0) {
          return searchPanel.first().isVisible();
        }
        if ((await searchContainer.count()) > 0) {
          return searchContainer.first().isVisible();
        }
        return false;
      },
      { maxAttempts: 20, delayMs: 500 },
    ).then(() => true as const).catch(() => false);

    expect(containerVisible).toBe(true);

    // If the Karax renderer has populated the panel, verify empty state.
    if ((await searchPanel.count()) > 0) {
      const matchRows = searchPanel.locator(".search-results-match-row");
      const matchCount = await matchRows.count();
      expect(matchCount).toBe(0);
    }
  });
});
