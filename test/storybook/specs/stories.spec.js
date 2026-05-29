const { test, expect } = require("@playwright/test");
const storyUrls = require("../support/story-urls.json");

const STORY_CONTENT_SELECTOR = "div#story-live";

test.describe("Storybook smoke", () => {
  for (const url of storyUrls) {
    test(`story renders: ${url}`, async ({ page }) => {
      const consoleErrors = [];
      const pageErrors = [];

      page.on("console", (msg) => {
        if (msg.type() === "error") consoleErrors.push(msg.text());
      });

      page.on("pageerror", (err) => pageErrors.push(err.message));

      await page.goto(url);

      // Timeout here means the story page itself failed to mount.
      await page.locator(STORY_CONTENT_SELECTOR).waitFor({ timeout: 10_000 });

      // Fail on uncaught JS exceptions.
      if (pageErrors.length > 0) {
        throw new Error(
          [
            `Uncaught JS exception(s) at ${url}:`,
            pageErrors.map((e) => `  • ${e}`).join("\n"),
            consoleErrors.length > 0
              ? `Console errors:\n${consoleErrors.map((e) => `  • ${e}`).join("\n")}`
              : null,
          ]
            .filter(Boolean)
            .join("\n\n")
        );
      }
    });
  }
});
