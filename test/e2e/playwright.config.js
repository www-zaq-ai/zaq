const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./specs",
  fullyParallel: false,
  workers: 1,
  timeout: 120_000,
  expect: {
    timeout: 15_000,
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
