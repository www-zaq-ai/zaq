const { defineConfig, devices } = require("@playwright/test");

// Retries are deliberately 0. Do NOT bump this to mask flakes — the plan
// `docs/exec-plans/active/2026-04-20-fix-e2e-flakiness.md` explicitly forbids
// hiding real races behind retries.
module.exports = defineConfig({
  testDir: "./specs",
  globalSetup: require.resolve("./support/global-setup"),
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: {
    timeout: process.env.CI ? 20_000 : 15_000,
  },
  reporter: process.env.CI
    ? [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]]
    : [["list"]],
  use: {
    baseURL: "http://localhost:4002",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    headless: !process.env.SLOW,
    launchOptions: {
      slowMo: process.env.SLOW ? (parseInt(process.env.SLOW, 10) >= 100 ? parseInt(process.env.SLOW, 10) : 1000) : 0,
    },
  },
  webServer: {
    command:
      "sh -c 'cd ../.. && PORT=4002 MIX_ENV=test E2E=1 MIX_BUILD_PATH=_build/test-e2e mix phx.server'",
    url: "http://localhost:4002/bo/login",
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
      },
    },
  ],
});
