const { test } = require("@playwright/test");

const STORY_LINK_SELECTOR = "section#sidebar a[href^='/storybook'][data-phx-link='patch']";
const STORY_CONTENT_SELECTOR = "div#story-live";

let storyUrls = [];

test.beforeAll(async ({ browser }) => {
  const page = await browser.newPage();

  // If this times out, the sidebar selector is wrong or the dev server isn't
  // serving Storybook. Open http://localhost:4000/storybook in DevTools to verify.
  await page.goto("/storybook");
  await page.waitForSelector(STORY_LINK_SELECTOR, { timeout: 15_000 });

  const hrefs = await page.$$eval(STORY_LINK_SELECTOR, (links) =>
    [...new Set(links.map((a) => a.getAttribute("href")).filter(Boolean))]
  );
  await page.close();

  if (hrefs.length === 0) {
    throw new Error(
      [
        "Sidebar discovery returned 0 story links.",
        `Selector used: ${STORY_LINK_SELECTOR}`,
        "Open http://localhost:4000/storybook in DevTools and verify the selector.",
      ].join("\n")
    );
  }

  storyUrls = hrefs;
  console.log(`Discovered ${storyUrls.length} stories.`);
});

// One test per story URL — each shows as an individual row in the Playwright
// report with its own screenshot on failure.
storyUrls.forEach((url) => {
  test(`story renders: ${url}`, async ({ page }) => {
    const consoleErrors = [];
    const pageErrors = [];

    page.on("console", (msg) => {
      if (msg.type() === "error") consoleErrors.push(msg.text());
    });

    page.on("pageerror", (err) => pageErrors.push(err.message));

    await page.goto(url);

    // Timeout here means the story page itself failed to mount.
    await page.waitForSelector(STORY_CONTENT_SELECTOR, { timeout: 10_000 });

    // Fail if the page threw uncaught JS exceptions.
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
});
