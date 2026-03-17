const { expect } = require("@playwright/test");

const DEFAULT_BASE_URL = process.env.E2E_BASE_URL || "http://localhost:4002";
const DEFAULT_ADMIN_USERNAME = process.env.E2E_ADMIN_USERNAME || "e2e_admin";
const DEFAULT_ADMIN_PASSWORD = process.env.E2E_ADMIN_PASSWORD || "StrongPass1!";

const REQUIRED_ASSET_PATHS = ["/assets/js/app.js", "/assets/css/app.css"];

function normalizeBaseURL(baseURL) {
  return (baseURL || DEFAULT_BASE_URL).replace(/\/+$/, "");
}

async function ensureAssetsAvailable(page, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);

  for (const path of REQUIRED_ASSET_PATHS) {
    const response = await page.request.get(`${baseURL}${path}`);

    if (!response.ok()) {
      throw new Error(
        `Missing required asset ${path} (status ${response.status()}). Run \"mix assets.setup && mix assets.build\" before E2E.`
      );
    }
  }
}

async function waitForLiveViewConnected(page, options = {}) {
  const timeout = options.timeout || 15_000;
  const root = page.locator("[data-phx-main]").first();

  await expect(root).toBeVisible({ timeout });

  await page.waitForFunction(
    () => {
      const liveRoot = document.querySelector("[data-phx-main]");

      if (!liveRoot) {
        return false;
      }

      const socket = window.liveSocket;
      const socketConnected =
        socket && typeof socket.isConnected === "function" && socket.isConnected();

      return liveRoot.classList.contains("phx-connected") || socketConnected === true;
    },
    undefined,
    { timeout }
  );
}

async function gotoBackOfficeLive(page, path, options = {}) {
  await page.goto(path);

  if (options.ensureConnected !== false) {
    await waitForLiveViewConnected(page, options);
  }
}

async function loginToBackOffice(page, options = {}) {
  const username = options.username || DEFAULT_ADMIN_USERNAME;
  const password = options.password || DEFAULT_ADMIN_PASSWORD;

  await ensureAssetsAvailable(page, options);
  await gotoBackOfficeLive(page, "/bo/login", options);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    await page.locator('input[name="username"]').fill(username);
    await page.locator('input[name="password"]').fill(password);
    await page.getByRole("button", { name: "Sign In to Dashboard" }).click();

    try {
      await expect(page).toHaveURL(/\/bo\/(dashboard|change-password)/, { timeout: 7000 });
      await waitForLiveViewConnected(page, options);
      return;
    } catch (_error) {
      await gotoBackOfficeLive(page, "/bo/login", options);
    }
  }

  await expect(page).toHaveURL(/\/bo\/(dashboard|change-password)/);
  await waitForLiveViewConnected(page, options);
}

module.exports = {
  ensureAssetsAvailable,
  gotoBackOfficeLive,
  loginToBackOffice,
  waitForLiveViewConnected,
};
