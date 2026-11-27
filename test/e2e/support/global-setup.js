const { request } = require("@playwright/test");
const fs = require("fs");
const path = require("path");

const STORYBOOK_URL = "http://localhost:4000";
const REQUIRED_ASSET_PATHS = ["/assets/js/app.js", "/assets/css/app.css"];
const STORYBOOK_DIR = path.join(__dirname, "..", "..", "..", "storybook");
const STORY_URLS_PATH = path.join(__dirname, "story-urls.json");

function discoverStoryFiles(dir) {
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...discoverStoryFiles(full));
    } else if (entry.isFile() && entry.name.endsWith(".story.exs")) {
      results.push(full);
    }
  }
  return results;
}

function fileToUrl(filePath) {
  const rel = path.relative(STORYBOOK_DIR, filePath);
  const withoutExt = rel.replace(/\.story\.exs$/, "");
  return "/storybook/" + withoutExt.split(path.sep).join("/");
}

// Runs exactly once before the whole suite. Used to:
//   1) Verify compiled assets are available.
//   2) Discover the stories for the storybook smoke specs.
//
// The browser journeys (test/e2e_pw) have their own global setup:
// test/support/e2e_pw/global_setup.ex.
module.exports = async () => {
  const ctx = await request.newContext({ baseURL: STORYBOOK_URL });

  for (const path of REQUIRED_ASSET_PATHS) {
    const res = await ctx.get(path);
    if (!res.ok()) {
      throw new Error(
        `Missing required asset ${path} (status ${res.status()}). ` +
          `Run \"mix assets.setup && mix assets.build\" before E2E.`
      );
    }
  }

  await ctx.dispose();

  const storyFiles = discoverStoryFiles(STORYBOOK_DIR);
  const urls = storyFiles.map(fileToUrl).sort();
  if (urls.length === 0) {
    throw new Error(`No .story.exs files found under ${STORYBOOK_DIR}. Check the path.`);
  }
  fs.writeFileSync(STORY_URLS_PATH, JSON.stringify(urls, null, 2));
  console.log(`[storybook smoke] Discovered ${urls.length} stories → ${STORY_URLS_PATH}`);
};
