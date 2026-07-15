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

      // phx-connected means the LiveView channel has joined — a connected
      // socket alone still drops phx-click events fired before the join.
      return liveRoot.classList.contains("phx-connected") && socketConnected === true;
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

async function pickSearchableSelect(page, containerSel, optionLabel) {
  const trigger = page.locator(`${containerSel} [data-select-trigger]`)
  const panel = page.locator(`${containerSel} [data-select-panel]`)
  const search = page.locator(`${containerSel} [data-select-search]`)
  const option = page.locator(`${containerSel} [data-select-option="${optionLabel}"]`)

  await expect(trigger).toBeVisible()

  // LiveView can patch/remount this hook while dependent fields update.
  // Retry opening several times until the panel is actually visible.
  let opened = false
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await trigger.click({ force: true })
    try {
      await expect(panel).toBeVisible({ timeout: 600 })
      await expect(search).toBeVisible({ timeout: 600 })
      opened = true
      break
    } catch (_error) {
      await page.waitForTimeout(120)
    }
  }

  expect(opened).toBeTruthy()
  await search.fill(optionLabel)
  await expect(option).toBeVisible({ timeout: process.env.CI ? 10_000 : 5_000 })
  await option.click()
}

// Creates an AI credential via the System Config AI Credentials tab.
// Caller must already be on the /bo/system-config page.
// Returns the credential object so callers can reference its name/provider.
async function createAiCredential(page, overrides = {}) {
  const unique = `${Date.now()}-${Math.floor(Math.random() * 10000)}`
  const credential = {
    name: overrides.name || `E2E Credential ${unique}`,
    provider: overrides.provider || "Custom",
    endpoint: overrides.endpoint,
    apiKey: overrides.apiKey || `e2e-key-${unique}`,
    sovereign: overrides.sovereign || false,
    description: overrides.description || "E2E credential",
  }

  await expect(async () => {
    await page.locator('[phx-value-tab="ai_credentials"]').click()
    await expect(page).toHaveURL(/tab=ai_credentials/, { timeout: 2_000 })
    await expect(page.locator('[phx-click="new_ai_credential"]')).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: process.env.CI ? 20_000 : 15_000 })

  await expect(async () => {
    await page.locator('[phx-click="new_ai_credential"]').click()
    await expect(page.locator("#ai-credential-form")).toBeVisible({ timeout: 2_000 })
  }).toPass({ timeout: process.env.CI ? 20_000 : 15_000 })

  await page.locator('input[name="ai_credential[name]"]').fill(credential.name)
  await pickSearchableSelect(page, "#ai-credential-provider-select", credential.provider)
  if (credential.endpoint !== undefined) {
    await page.locator('input[name="ai_credential[endpoint]"]').fill(credential.endpoint)
  }
  await page.locator("#ai-credential-api-key-input").fill(credential.apiKey)

  if (credential.sovereign) {
    await page.locator('label:has(input[name="ai_credential[sovereign]"][type="checkbox"])').click()
  }

  await page.locator('textarea[name="ai_credential[description]"]').fill(credential.description)
  await page.locator("#ai-credential-modal").getByRole("button", { name: "Save credential" }).click()

  await expect(page.getByText("AI credential saved.")).toBeVisible()
  await expect(page.locator("#ai-credential-form")).not.toBeVisible()
  await waitForLiveViewSettled(page)

  return credential
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

// Seed in-memory add-on package data (FeatureStore) for dashboard E2E.
// Body uses string keys: company_name, license_key, expires_at (ISO-8601), features (array of { name }).
async function createE2EAddonPackage(request, attrs, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/addon-package`, {
    data: attrs,
    headers: { "Content-Type": "application/json" },
  });
  if (!res.ok()) {
    throw new Error(`/e2e/addon-package returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
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

async function createE2EAiCredential(request, attrs, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/ai-credentials`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/ai-credentials returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

async function createE2EMcpEndpoint(request, attrs, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/mcp-endpoints`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/mcp-endpoints returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

async function createE2EAgent(request, attrs, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/agents`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/agents returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

// Seed a conversation for the E2E admin (see POST /e2e/conversations).
// Required: channel_type. Optional: title, channel_user_id, status ("active" | "archived"), user_id.
async function createE2EConversation(request, attrs, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/conversations`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/conversations returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

// Seed the initial "admin" user that satisfies bootstrap_admin_pending?/1.
// After this call, navigate to GET /bo/bootstrap-login — the server creates a
// session without a password and redirects straight to /bo/change-password.
// This mirrors the real first-run flow (no login form).
async function createE2EBootstrapAdmin(request, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/bootstrap-admin`);
  if (!res.ok()) {
    throw new Error(`/e2e/bootstrap-admin returned ${res.status()} ${await res.text()}`);
  }
}

// Seed a user pending bootstrap onboarding (must_change_password, no email).
// Returns { username, password } to feed into loginToBackOffice — logging in
// redirects to /bo/change-password, the onboarding flow under test.
async function createE2EOnboardingUser(request, attrs = {}, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/onboarding-user`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/onboarding-user returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

// Seed a user who completed bootstrap with portal_consent="declined".
// Optional attrs: { username, password, email } — omit email for a no-email user (Scenario 5).
// Returns { username, password, user_id }.
async function createE2EDeclinedPortalUser(request, attrs = {}, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/declined-portal-user`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/declined-portal-user returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

// Pre-register a conflicting email.
// The next portal_onboard call with that value returns a real 409.
// Conflicts are cleared by POST /e2e/reset.
async function registerE2EPortalConflict(request, attrs = {}, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/portal/conflicts`, { data: attrs });
  if (!res.ok()) {
    throw new Error(`/e2e/portal/conflicts returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

// Toggle the portal loopback stub's offline mode.
// When offline=true the metadata endpoint returns 503 (client treats as :unavailable).
async function setE2EPortalOffline(request, offline = true, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.post(`${baseURL}/e2e/portal/offline`, { data: { offline } });
  if (!res.ok()) {
    throw new Error(`/e2e/portal/offline returned ${res.status()} ${await res.text()}`);
  }
  return res.json();
}

async function getE2EZAQRouterCredential(request, options = {}) {
  const baseURL = normalizeBaseURL(options.baseURL);
  const res = await request.get(`${baseURL}/e2e/zaq-router-credential`);
  if (!res.ok() && res.status() !== 404) {
    throw new Error(
      `/e2e/zaq-router-credential returned ${res.status()} ${await res.text()}`
    );
  }
  return res.json();
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
  createE2EAddonPackage,
  setE2ESystemConfig,
  touchE2EFile,
  createE2EAiCredential,
  createE2EMcpEndpoint,
  createE2EAgent,
  createE2EConversation,
  createE2EBootstrapAdmin,
  createE2EOnboardingUser,
  createE2EDeclinedPortalUser,
  registerE2EPortalConflict,
  setE2EPortalOffline,
  getE2EZAQRouterCredential,
  pickSearchableSelect,
  createAiCredential,
};
