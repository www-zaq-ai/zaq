const { expect } = require("@playwright/test");

const DEFAULT_BASE_URL = process.env.E2E_BASE_URL || "http://localhost:4002";
const DEFAULT_ADMIN_USERNAME = process.env.E2E_ADMIN_USERNAME || "e2e_admin";
const DEFAULT_ADMIN_PASSWORD = process.env.E2E_ADMIN_PASSWORD || "StrongPass1!";

function normalizeBaseURL(baseURL) {
  return (baseURL || DEFAULT_BASE_URL).replace(/\/+$/, "");
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

// Waits until no LiveView component on the page carries a `phx-*-loading` class.
// Use after any phx-change / phx-click / phx-submit that mutates state the next
// assertion depends on. Safer than a fixed sleep and much safer than
// `isVisible()` probes on half-rendered markup.
async function waitForLiveViewSettled(page, options = {}) {
  const timeout = options.timeout || 10_000;
  await page.waitForFunction(
    () => {
      const loading = document.querySelectorAll(
        ".phx-change-loading, .phx-click-loading, .phx-submit-loading, .phx-disconnected"
      );
      return loading.length === 0;
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
  const maxAttempts = options.maxAttempts || 4;

  await gotoBackOfficeLive(page, "/bo/login", options);

  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    // Wait for LiveView to attach BEFORE touching the form — otherwise
    // .fill() fires a phx-change that the channel is not yet listening for,
    // and the subsequent submit becomes a plain POST that races with mount.
    await waitForLiveViewConnected(page, options);

    const userField = page.locator('input[name="username"]');
    const passField = page.locator('input[name="password"]');

    await expect(userField).toBeVisible({ timeout: 5_000 });
    await userField.fill(username);
    await passField.fill(password);
    await page.getByRole("button", { name: "Sign In to Dashboard" }).click();

    try {
      await expect(page).toHaveURL(/\/bo\/(dashboard|change-password)/, {
        timeout: 7_000 + attempt * 2_000,
      });
      await waitForLiveViewConnected(page, options);
      return;
    } catch (_error) {
      // Exponential-ish backoff: 0, 500, 1000, 1500 ms
      await page.waitForTimeout(attempt * 500);
      await gotoBackOfficeLive(page, "/bo/login", options);
    }
  }

  // Final assertion gives a clean failure message if all retries fell through.
  await expect(page).toHaveURL(/\/bo\/(dashboard|change-password)/);
  await waitForLiveViewConnected(page, options);
}

// Dismisses any visible flash toast so the NEXT test does not match on a
// leftover success message. Safe to call when no flash is present.
async function dismissFlash(page) {
  const flash = page.locator("[id^='flash-']").filter({ hasText: /./ });
  const count = await flash.count();
  if (count === 0) return;

  for (let i = 0; i < count; i += 1) {
    const item = flash.nth(i);
    const close = item.getByRole("button", { name: /close|dismiss/i });
    if (await close.count()) {
      await close.first().click().catch(() => {});
    }
  }

  await expect(flash).toHaveCount(0, { timeout: 5_000 }).catch(() => {});
}

// Small helper for the common "server just processed a phx event" wait.
// Returns a promise that resolves when the page is connected AND idle.
async function waitForServerRoundTrip(page) {
  await waitForLiveViewConnected(page);
  await waitForLiveViewSettled(page);
}

// Hit POST /e2e/reset. Call from a describe-level beforeAll so tests start on
// a predictable DB (baseline embedding config, baseline fixtures, empty
// ingest_jobs, empty ai_provider_credentials, empty people/teams, etc).
async function resetE2EState(request, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/reset`);
  if (!res.ok()) {
    throw new Error(`/e2e/reset returned ${res.status()} ${await res.text()}`);
  }
}

async function setE2ESystemConfig(request, key, value, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/system-config`, {
    data: { key, value },
  });

  if (!res.ok()) {
    throw new Error(`/e2e/system-config returned ${res.status()} ${await res.text()}`);
  }
}

// Server-side mtime bump. Use in place of `page.waitForTimeout(...)` when a
// test needs a file to look newer than a document row's updated_at.
async function touchE2EFile(request, relativePath, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/ingestion/touch_file`, {
    params: { path: relativePath },
  });
  if (!res.ok()) {
    throw new Error(`/e2e/ingestion/touch_file returned ${res.status()} ${await res.text()}`);
  }
}

module.exports = {
  gotoBackOfficeLive,
  loginToBackOffice,
  waitForLiveViewConnected,
  waitForLiveViewSettled,
  waitForServerRoundTrip,
  dismissFlash,
  normalizeBaseURL,
  resetE2EState,
  setE2ESystemConfig,
  touchE2EFile,
};
