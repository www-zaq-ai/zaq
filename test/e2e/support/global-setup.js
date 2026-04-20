const { request } = require("@playwright/test");

const BASE_URL = process.env.E2E_BASE_URL || "http://localhost:4002";
const REQUIRED_ASSET_PATHS = ["/assets/js/app.js", "/assets/css/app.css"];

// Runs exactly once before the whole suite. Used to:
//   1) Verify compiled assets are available (was previously repeated on every login).
//   2) Hit /e2e/health to confirm the server booted with E2E=1.
//
// Everything needed for per-describe isolation (DB reset, processor state) is
// owned by the suites via POST /e2e/reset — see step 2 of the flakiness plan.
module.exports = async () => {
  const ctx = await request.newContext({ baseURL: BASE_URL });

  for (const path of REQUIRED_ASSET_PATHS) {
    const res = await ctx.get(path);
    if (!res.ok()) {
      throw new Error(
        `Missing required asset ${path} (status ${res.status()}). ` +
          `Run \"mix assets.setup && mix assets.build\" before E2E.`
      );
    }
  }

  const health = await ctx.get("/e2e/health");
  if (!health.ok()) {
    throw new Error(
      `/e2e/health returned ${health.status()}. Server must boot with E2E=1.`
    );
  }

  await ctx.dispose();
};
