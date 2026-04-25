import type { Locator, Page } from "@playwright/test";

/**
 * Wraps the build output component within the layout.
 *
 * The build panel renders stdout lines with class "build-stdout"
 * and stderr lines with class "build-stderr".
 */
export class BuildPane {
  readonly page: Page;
  readonly root: Locator;

  constructor(page: Page) {
    this.page = page;
    // The build panel uses id="build"
    this.root = page.locator("#build");
  }

  /**
   * Returns all stdout output lines in the build panel.
   */
  stdoutLines(): Locator {
    return this.root.locator(".build-stdout");
  }

  /**
   * Returns all stderr output lines in the build panel.
   */
  stderrLines(): Locator {
    return this.root.locator(".build-stderr");
  }

  /**
   * Returns all output lines (both stdout and stderr) in the build panel.
   */
  allLines(): Locator {
    return this.root.locator(".build-stdout, .build-stderr");
  }

  /**
   * Returns the build errors panel.
   */
  errorsPanel(): Locator {
    return this.page.locator("#build-errors");
  }

  /**
   * Checks whether the build panel is present in the DOM.
   */
  async isPresent(): Promise<boolean> {
    return (await this.root.count()) > 0;
  }

  /**
   * Checks whether the build panel is visible.
   */
  async isVisible(): Promise<boolean> {
    if (!(await this.isPresent())) {
      return false;
    }
    return this.root.first().isVisible();
  }

  /**
   * Returns the computed color CSS property of the first stderr line,
   * or null if no stderr lines exist.
   */
  async stderrColor(): Promise<string | null> {
    const count = await this.stderrLines().count();
    if (count === 0) {
      return null;
    }
    return this.stderrLines().first().evaluate(
      (el) => window.getComputedStyle(el).color,
    );
  }

  /**
   * Returns the computed color CSS property of the first stdout line,
   * or null if no stdout lines exist.
   */
  async stdoutColor(): Promise<string | null> {
    const count = await this.stdoutLines().count();
    if (count === 0) {
      return null;
    }
    return this.stdoutLines().first().evaluate(
      (el) => window.getComputedStyle(el).color,
    );
  }
}
