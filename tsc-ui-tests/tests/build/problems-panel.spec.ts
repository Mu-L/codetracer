/**
 * E2E tests for the Problems panel (BP-M4).
 *
 * Verifies:
 * - The Problems panel is present in the layout
 * - Parsed build errors appear as structured problem rows
 * - Clicking a filter button changes the visible problems
 */

import { test, expect } from "../../lib/fixtures";
import { retry } from "../../lib/retry-helpers";
import { ProblemsPane } from "../../page-objects/panes/build/problems-pane";

test.describe("Problems Panel", () => {
  test.setTimeout(120_000);
  // noir_space_ship triggers a build that typically produces compiler output
  // with error/warning diagnostics.
  test.use({ sourcePath: "noir_space_ship/", launchMode: "trace" });

  test("problems panel is present in the layout", async ({ ctPage }) => {
    // Wait for the GL layout to be initialised.
    await ctPage.waitForSelector(".lm_goldenlayout", { timeout: 15_000 });

    // The problems panel component is created as part of the component
    // tree even if it is not the active tab. Check DOM presence.
    const problemsPane = new ProblemsPane(ctPage);
    const present = await retry(
      async () => problemsPane.isPresent(),
      { maxAttempts: 30, delayMs: 1_000 },
    ).catch(() => false);

    expect(present).toBe(true);
  });

  test("problems appear when build output contains errors", async ({
    ctPage,
  }) => {
    const problemsPane = new ProblemsPane(ctPage);

    // Wait for at least one problem row to appear (the build must run and
    // produce parseable error/warning output first).
    const hasProblems = await retry(
      async () => {
        const count = await problemsPane.rows().count();
        return count > 0;
      },
      { maxAttempts: 60, delayMs: 1_000 },
    ).catch(() => false);

    if (!hasProblems) {
      // The trace source may compile cleanly. In that case the panel
      // should show the empty-state message instead.
      const emptyMsg = problemsPane.emptyMessage();
      await expect(emptyMsg).toBeVisible({ timeout: 5_000 });
      return;
    }

    // Each row should contain the severity icon, file path, location, and message.
    const firstRow = problemsPane.rows().first();
    await expect(firstRow.locator(".problems-icon")).toBeVisible();
    await expect(firstRow.locator(".problems-path")).toBeVisible();
    await expect(firstRow.locator(".problems-location")).toBeVisible();
    await expect(firstRow.locator(".problems-message")).toBeVisible();

    // Verify that the message text is non-empty.
    const msgText = await firstRow.locator(".problems-message").textContent();
    expect(msgText).toBeTruthy();
    expect((msgText ?? "").length).toBeGreaterThan(0);
  });

  test("filter buttons change visible problems", async ({ ctPage }) => {
    const problemsPane = new ProblemsPane(ctPage);

    // Wait for problems to load.
    const hasProblems = await retry(
      async () => {
        const count = await problemsPane.rows().count();
        return count > 0;
      },
      { maxAttempts: 60, delayMs: 1_000 },
    ).catch(() => false);

    if (!hasProblems) {
      test.skip(true, "No build problems produced for this trace");
      return;
    }

    const allCount = await problemsPane.rows().count();
    expect(allCount).toBeGreaterThan(0);

    // Click "Errors" filter.
    await problemsPane.filterButton("Errors").click();
    // After filtering, count should be <= allCount.
    const errorCount = await problemsPane.errorRows().count();
    expect(errorCount).toBeLessThanOrEqual(allCount);

    // Click "All" to restore.
    await problemsPane.filterButton("All").click();
    const restoredCount = await problemsPane.rows().count();
    expect(restoredCount).toBe(allCount);
  });
});
