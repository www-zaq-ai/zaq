const { chromium, request } = require("@playwright/test");
const fs = require("fs");
const path = require("path");

const STORY_LINK_SELECTOR = "section#sidebar a[href^='/storybook'][data-phx-link='patch']";
const OUTPUT_PATH = path.join(__dirname, "story-urls.json");
const BASE_URL = "http://localhost:4000";

module.exports = async () => {
  // globalSetup runs before webServer starts. Poll until the dev server is ready.
  const pollCtx = await request.newContext({ baseURL: BASE_URL });
  let serverReady = false;
  for (let i = 0; i < 45; i++) {
    try {
      const res = await pollCtx.get("/storybook");
      if (res.ok()) { serverReady = true; break; }
    } catch (_) {}
    await new Promise((r) => setTimeout(r, 2_000));
  }
  await pollCtx.dispose();
  if (!serverReady) {
    throw new Error(`Dev server at ${BASE_URL}/storybook did not become ready in 90s.`);
  }

  const browser = await chromium.launch();
  const page = await browser.newPage();

  try {
    await page.goto(`${BASE_URL}/storybook`);
    await page.locator(STORY_LINK_SELECTOR).waitFor({ timeout: 15_000 });

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
