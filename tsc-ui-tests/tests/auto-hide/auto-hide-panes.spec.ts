/**
 * Auto-hide panes E2E tests.
 *
 * Verifies the pin-to-edge workflow: pinning panels to edge strips,
 * opening overlays via strip tabs, unpinning back to the GL layout,
 * and dismissing overlays via Escape / backdrop click.
 *
 * DOM elements under test (defined in index.html and rendered by
 * auto_hide.nim / auto_hide_overlay.nim):
 *   #auto-hide-strips            — container for all three edge strips
 *   .auto-hide-strip-bottom      — bottom edge strip
 *   .auto-hide-strip-left        — left edge strip
 *   .auto-hide-strip-right       — right edge strip
 *   .auto-hide-strip-tab         — individual tab within a strip
 *   #auto-hide-overlay           — slide-in overlay container
 *   #auto-hide-overlay-title     — title text inside overlay header
 *   #auto-hide-overlay-unpin-btn — "Unpin" button in overlay header
 *   #auto-hide-overlay-close-btn — close button in overlay header
 *   #auto-hide-backdrop          — click-to-dismiss backdrop behind overlay
 *   .layout-buttons-container    — GL stack header dropdown toggle
 *   .layout-dropdown-node        — individual item inside the dropdown
 */

import { test, expect, wait } from "../../lib/fixtures";
import { LayoutPage } from "../../page-objects/layout-page";

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

/** Timeout for waiting on DOM mutations after pin/unpin actions. */
const ACTION_SETTLE_MS = 1500;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Open the dropdown menu on the first visible GL stack header and click
 * the menu item whose text matches `itemText` (e.g. "Pin to Bottom").
 *
 * The dropdown is a `.layout-buttons-container` div rendered in each
 * stack header. Clicking it toggles a child `.layout-dropdown` between
 * hidden and visible. Menu items are `.layout-dropdown-node` elements.
 *
 * Returns the title text of the active tab in the stack that was acted
 * upon, so tests can assert which panel was pinned.
 */
async function clickDropdownItem(
  ctPage: import("@playwright/test").Page,
  itemText: string,
  stackIndex = 0,
): Promise<string> {
  // Find the stack's active tab title before acting, so we know
  // which panel will be pinned.
  const stacks = ctPage.locator(".lm_stack");
  const stack = stacks.nth(stackIndex);
  await expect(stack).toBeVisible({ timeout: 10_000 });

  // The active tab label lives inside .lm_tab.lm_active .lm_title
  const activeTitle = await stack
    .locator(".lm_tab.lm_active .lm_title")
    .first()
    .textContent();

  // Click the dropdown toggle (the container div in the stack header).
  const toggle = stack.locator(".layout-buttons-container").first();
  await toggle.click();

  // Wait for the dropdown to become visible (hidden class removed).
  const dropdown = stack.locator(".layout-dropdown").first();
  await expect(dropdown).not.toHaveClass(/hidden/, { timeout: 5_000 });

  // Click the desired menu item.
  const menuItem = dropdown.locator(".layout-dropdown-node", {
    hasText: itemText,
  });
  await expect(menuItem).toBeVisible({ timeout: 5_000 });
  await menuItem.click();

  // Allow the pin action to settle (DOM removal + strip re-render).
  await wait(ACTION_SETTLE_MS);

  return (activeTitle ?? "").trim();
}

/**
 * Pin the active tab of a given GL stack to the specified edge.
 * Returns the title of the panel that was pinned.
 */
async function pinToEdge(
  ctPage: import("@playwright/test").Page,
  edge: "Bottom" | "Left" | "Right",
  stackIndex = 0,
): Promise<string> {
  return clickDropdownItem(ctPage, `Pin to ${edge}`, stackIndex);
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe("Auto-hide panes", () => {
  test.setTimeout(120_000);
  test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace" });

  test("strip tabs hidden when no panels pinned", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // No panels are pinned by default, so no strip tabs should be present.
    const stripTabs = ctPage.locator(".auto-hide-strip-tab");
    await expect(stripTabs).toHaveCount(0);

    // Each individual strip should either be absent or empty (CSS hides
    // empty strips via :empty { display: none }).
    for (const stripClass of [
      ".auto-hide-strip-bottom",
      ".auto-hide-strip-left",
      ".auto-hide-strip-right",
    ]) {
      const strip = ctPage.locator(stripClass);
      const count = await strip.count();
      if (count > 0) {
        // Strip div exists but should contain no tabs.
        const innerTabs = strip.locator(".auto-hide-strip-tab");
        await expect(innerTabs).toHaveCount(0);
      }
    }
  });

  test("pin panel creates strip tab", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Record the initial number of GL stacks so we can verify one was removed.
    const initialStackCount = await ctPage.locator(".lm_stack").count();

    // Pin the active tab of the first stack to the bottom edge.
    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // A strip tab should now exist in the bottom strip.
    const bottomStrip = ctPage.locator(".auto-hide-strip-bottom");
    const bottomTabs = bottomStrip.locator(".auto-hide-strip-tab");
    await expect(bottomTabs).toHaveCount(1, { timeout: 5_000 });

    // The strip tab text should match the pinned panel title.
    await expect(bottomTabs.first()).toHaveText(pinnedTitle);

    // The panel should have been removed from the GL layout (one fewer
    // component, which may reduce the stack count or the tab count).
    const currentStackCount = await ctPage.locator(".lm_stack").count();
    // If the stack had only one tab, the entire stack is removed.
    // If it had multiple tabs, the stack remains but with fewer tabs.
    // Either way, the total visible tab count should have decreased.
    const remainingTabsWithTitle = ctPage.locator(".lm_tab .lm_title", {
      hasText: pinnedTitle,
    });
    await expect(remainingTabsWithTitle).toHaveCount(0);
  });

  test("strip tab click shows overlay", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Click the strip tab.
    const stripTab = ctPage.locator(".auto-hide-strip-tab").first();
    await expect(stripTab).toBeVisible({ timeout: 5_000 });
    await stripTab.click();
    await wait(500);

    // The overlay should become visible (has the "visible" CSS class).
    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // The overlay title should match the pinned panel.
    const overlayTitle = ctPage.locator("#auto-hide-overlay-title");
    await expect(overlayTitle).toHaveText(pinnedTitle);
  });

  test("overlay unpin restores panel", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    const pinnedTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay by clicking the strip tab.
    const stripTab = ctPage.locator(".auto-hide-strip-tab").first();
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Click "Unpin" to restore the panel back into GL.
    const unpinBtn = ctPage.locator("#auto-hide-overlay-unpin-btn");
    await expect(unpinBtn).toBeVisible();
    await unpinBtn.click();
    await wait(ACTION_SETTLE_MS);

    // The overlay should no longer be visible.
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The strip tab should have been removed.
    const remainingTabs = ctPage.locator(".auto-hide-strip-tab");
    await expect(remainingTabs).toHaveCount(0);

    // The panel should be back in the GL layout — look for its title
    // among GL tab titles.
    const restoredTab = ctPage.locator(".lm_tab .lm_title", {
      hasText: pinnedTitle,
    });
    await expect(restoredTab.first()).toBeVisible({ timeout: 5_000 });
  });

  test("overlay dismisses on Escape", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay.
    const stripTab = ctPage.locator(".auto-hide-strip-tab").first();
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Press Escape to dismiss.
    await ctPage.keyboard.press("Escape");
    await wait(500);

    // The overlay should be hidden (no "visible" class).
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The strip tab should still be present (Escape only hides the
    // overlay; it does not unpin the panel).
    const tabsAfter = ctPage.locator(".auto-hide-strip-tab");
    await expect(tabsAfter).toHaveCount(1);
  });

  test("overlay dismisses on backdrop click", async ({ ctPage }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    await pinToEdge(ctPage, "Bottom", 0);

    // Open the overlay.
    const stripTab = ctPage.locator(".auto-hide-strip-tab").first();
    await stripTab.click();
    await wait(500);

    const overlay = ctPage.locator("#auto-hide-overlay");
    await expect(overlay).toHaveClass(/visible/, { timeout: 5_000 });

    // Click the backdrop to dismiss.
    const backdrop = ctPage.locator("#auto-hide-backdrop");
    // The backdrop may be zero-sized when not shown; force the click
    // at a known position to ensure the event fires.
    await backdrop.click({ force: true });
    await wait(500);

    // The overlay should be hidden.
    await expect(overlay).not.toHaveClass(/visible/, { timeout: 5_000 });

    // The strip tab should still be present.
    const tabsAfter = ctPage.locator(".auto-hide-strip-tab");
    await expect(tabsAfter).toHaveCount(1);
  });

  test("multiple panels can be pinned to different edges", async ({
    ctPage,
  }) => {
    const layout = new LayoutPage(ctPage);
    await layout.waitForAllComponentsLoaded();
    await layout.waitForTraceLoaded();

    // Pin the first stack's active tab to the bottom.
    const bottomTitle = await pinToEdge(ctPage, "Bottom", 0);

    // Pin another stack's active tab to the left.
    // After the first pin, stack indices may shift, so we still target
    // index 0 which is now the next available stack.
    const leftTitle = await pinToEdge(ctPage, "Left", 0);

    // Bottom strip should have exactly one tab.
    const bottomTabs = ctPage
      .locator(".auto-hide-strip-bottom .auto-hide-strip-tab");
    await expect(bottomTabs).toHaveCount(1, { timeout: 5_000 });
    await expect(bottomTabs.first()).toHaveText(bottomTitle);

    // Left strip should have exactly one tab.
    const leftTabs = ctPage
      .locator(".auto-hide-strip-left .auto-hide-strip-tab");
    await expect(leftTabs).toHaveCount(1, { timeout: 5_000 });
    await expect(leftTabs.first()).toHaveText(leftTitle);

    // Neither panel should remain in the GL layout.
    const remainingBottom = ctPage.locator(".lm_tab .lm_title", {
      hasText: bottomTitle,
    });
    await expect(remainingBottom).toHaveCount(0);

    const remainingLeft = ctPage.locator(".lm_tab .lm_title", {
      hasText: leftTitle,
    });
    await expect(remainingLeft).toHaveCount(0);
  });
});
