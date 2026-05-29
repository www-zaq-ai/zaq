const { chromium } = require("@playwright/test");
const fs = require("fs");
const path = require("path");

const STORY_LINK_SELECTOR = "section#sidebar a[href^='/storybook'][data-phx-link='patch']";
const OUTPUT_PATH = path.join(__dirname, "story-urls.json");

module.exports = async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();

  try {
    await page.goto("http://localhost:4000/storybook");
    await page.waitForSelector(STORY_LINK_SELECTOR, { timeout: 15_000 });

    const hrefs = await page.$$eval(STORY_LINK_SELECTOR, (links) =>
      [...new Set(links.map((a) => a.getAttribute("href")).filter(Boolean))]
    );

    if (hrefs.length === 0) {
      throw new Error(
        [
          "Sidebar discovery returned 0 story links.",
          `Selector used: ${STORY_LINK_SELECTOR}`,
          "Open http://localhost:4000/storybook in DevTools and verify the selector.",
        ].join("\n")
      );
    }

    fs.writeFileSync(OUTPUT_PATH, JSON.stringify(hrefs, null, 2));
    console.log(`[storybook smoke] Discovered ${hrefs.length} stories → ${OUTPUT_PATH}`);
  } finally {
    await browser.close();
  }
};
