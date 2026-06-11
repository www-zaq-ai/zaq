const { test } = require("@playwright/test");
const storyUrls = require("../support/story-urls.json");

const STORY_CONTENT_SELECTOR = "div#psb-story-live";

// PhoenixStorybook loads both its own LiveSocket and the app's app.js LiveSocket.
// During cold navigation, a transient "Cannot bind multiple views" error fires
// during the two-socket initialization race. This resolves once the page settles.
// We filter these transient errors and only fail on real post-load exceptions.
const LIVESOCKET_INIT_ERROR = /Cannot bind multiple views|already been bound to a view/;

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

      // Timeout here means the story page itself failed to mount (e.g. compile error).
      await page.locator(STORY_CONTENT_SELECTOR).waitFor({ timeout: 10_000 });

      // Wait for the page to settle — flushes the LiveSocket init race before we check errors.
      await page.waitForLoadState("networkidle");

      // Exclude transient LiveSocket init errors that fire during cold navigation
      // and resolve on their own once the socket handshake completes.
      const realPageErrors = pageErrors.filter((e) => !LIVESOCKET_INIT_ERROR.test(e));
      const realConsoleErrors = consoleErrors.filter((e) => !LIVESOCKET_INIT_ERROR.test(e));

      if (realPageErrors.length > 0) {
        throw new Error(
          [
            `Uncaught JS exception(s) at ${url}:`,
            realPageErrors.map((e) => `  • ${e}`).join("\n"),
            realConsoleErrors.length > 0
              ? `Console errors:\n${realConsoleErrors.map((e) => `  • ${e}`).join("\n")}`
              : null,
          ]
            .filter(Boolean)
            .join("\n\n")
        );
      }
    });
  }
});
