const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./specs",
  globalSetup: require.resolve("./support/global-setup"),
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: {
    timeout: 15_000,
  },
  reporter: process.env.CI
    ? [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]]
    : [["list"]],
  use: {
    baseURL: "http://localhost:4000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    headless: !process.env.SLOW,
  },
  webServer: {
    command: "sh -c 'cd ../.. && mix phx.server'",
    url: "http://localhost:4000/storybook",
    // Reuses running dev server locally (fast), starts fresh on CI (safe).
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
