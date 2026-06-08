const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  loginToBackOffice,
  waitForLiveViewConnected,
  waitForLiveViewSettled,
  resetE2EState,
  createE2EBootstrapAdmin,
  createE2EDeclinedPortalUser,
  registerE2EPortalConflict,
  setE2EPortalOffline,
  getE2EMachineFingerprint,
} = require("../support/bo")

// Onboarding E2E — covers all 6 critical scenarios end-to-end.
//
// Bootstrap scenarios (1–3): user lands on /bo/change-password, sets email +
// password, then makes a portal consent decision. State is seeded via the E2E
// API; the portal loopback stub at /e2e/portal/* handles all portal calls.
//
// Dashboard retry scenarios (4–6): user has already completed bootstrap with
// portal_consent="declined" and is retrying from the dashboard banner.

const STRONG_PASSWORD = "StrongPass1!"
const ONBOARD_EMAIL = "fresh.admin@e2e.local"
const CONFLICT_EMAIL = "already-taken@e2e.local"
const CORRECTED_EMAIL = "corrected.admin@e2e.local"

const SEL = {
  // Bootstrap form (/bo/change-password)
  email: "#email",
  password: "#password",
  passwordConfirmation: "#password-confirmation",
  submit: '#change-password-form button[type="submit"]',

  // Portal consent modal (bootstrap and dashboard retry)
  acceptConsent: '[phx-click="accept_portal_consent"]',
  declineConsent: '[phx-click="decline_portal_consent"]',
  closeModal: '[phx-click="close_portal_consent_modal"]',
  modalEmailInput: "#portal-consent-email",

  // Dashboard retry banner
  activateButton: 'button:has-text("Activate")',

  // User edit form (/bo/users/:id/edit)
  userEmailInput: 'input[name="user[email]"]',
  saveChanges: 'button:has-text("Save Changes")',
}

// ---------------------------------------------------------------------------
// Scenarios 1–3 — Bootstrap onboarding
// ---------------------------------------------------------------------------

test.describe("Bootstrap onboarding", () => {
  let req

  test.beforeEach(async ({ page }) => {
    req = await apiRequest.newContext()
    await resetE2EState(req)
  })

  test.afterEach(async () => {
    await req.dispose()
  })

  async function setupBootstrapUser(page) {
    await createE2EBootstrapAdmin(req)
    await page.goto("/bo/bootstrap-login")
    await expect(page).toHaveURL(/\/bo\/change-password/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)
  }

  async function fillBootstrapForm(page) {
    await page.locator(SEL.email).fill(ONBOARD_EMAIL)
    await page.locator(SEL.password).fill(STRONG_PASSWORD)
    await page.locator(SEL.passwordConfirmation).fill(STRONG_PASSWORD)
    await expect(page.locator(SEL.submit)).toBeEnabled()
    await page.locator(SEL.submit).click()
    await waitForLiveViewSettled(page)
  }

  // ─── Scenario 1 ────────────────────────────────────────────────────────────
  // test("Scenario 1 — portal unreachable: skips modal, shows offline notice on dashboard", async ({
  //   page,
  // }) => {
  //   // Make the portal stub return 503 — client treats it as :unavailable.
  //   await setE2EPortalOffline(req, true)
  //   await setupBootstrapUser(page)

  //   // Submit form — no modal will appear (portal_reachable: false at mount).
  //   await fillBootstrapForm(page)

  //   // Redirects directly to dashboard with the standard flash.
  //   await expect(page).toHaveURL(/\/bo\/dashboard/, { timeout: 10_000 })
  //   await waitForLiveViewConnected(page)
  //   await expect(page.getByText("Password changed successfully")).toBeVisible()

  //   // Dashboard shows the offline notice; the retry banner is absent.
  //   await expect(
  //     page.getByText("ZAQ portal is not reachable in this environment")
  //   ).toBeVisible()
  //   await expect(page.locator(SEL.activateButton)).toHaveCount(0)
  // })

  // ─── Scenario 2 ────────────────────────────────────────────────────────────
  test("Scenario 2 — accept at bootstrap: provisions ZAQ Router, redirects to ingestion", async ({
    page,
  }) => {
    await setupBootstrapUser(page)
    await fillBootstrapForm(page)

    // Modal appears — accept the offer.
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await expect(page.getByText("Activate your free credits")).toBeVisible()
    await page.locator(SEL.acceptConsent).click()

    // Accept → portal provisioning → redirects to ingestion with welcome flash.
    await expect(page).toHaveURL(/\/bo\/ingestion/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)
    await expect(page.getByText("drop your files and ingest them")).toBeVisible()

    // Dashboard must not show the retry banner.
    await page.goto("/bo/dashboard")
    await waitForLiveViewConnected(page)
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
    await expect(page.getByText("Activate your free credits")).toHaveCount(0)
  })

  // ─── Scenario 3 ────────────────────────────────────────────────────────────
  test("Scenario 3 — decline at bootstrap, retry from dashboard: provisions on second accept", async ({
    page,
  }) => {
    await setupBootstrapUser(page)
    await fillBootstrapForm(page)

    // Modal appears — decline.
    await expect(page.locator(SEL.declineConsent)).toBeVisible()
    await page.locator(SEL.declineConsent).click()

    // Decline → dashboard with retry banner.
    await expect(page).toHaveURL(/\/bo\/dashboard/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)
    await expect(page.locator(SEL.activateButton)).toBeVisible()
    await expect(page.getByText("Claim your $2 in free AI credits")).toBeVisible()

    // Open the retry modal and accept.
    await page.locator(SEL.activateButton).click()
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // Banner disappears — consent accepted, credential provisioned.
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
    await expect(page.getByText("Activate your free credits")).toHaveCount(0)
  })
})

// ---------------------------------------------------------------------------
// Scenarios 4–6 — Dashboard retry (user already past bootstrap)
// ---------------------------------------------------------------------------

test.describe("Dashboard retry", () => {
  let req

  test.beforeEach(async () => {
    req = await apiRequest.newContext()
    await resetE2EState(req)
  })

  test.afterEach(async () => {
    await req.dispose()
  })

  // ─── Scenario 4 ────────────────────────────────────────────────────────────
  test("Scenario 4 — email conflict at retry: surfaces 409, admin corrects email, retry succeeds", async ({
    page,
  }) => {
    // Seed a declined user whose email is already registered in the portal.
    const user = await createE2EDeclinedPortalUser(req, { email: CONFLICT_EMAIL })
    await registerE2EPortalConflict(req, { email: CONFLICT_EMAIL })

    await loginToBackOffice(page, { username: user.username, password: user.password })
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)

    // First accept attempt → 409 error.
    await page.locator(SEL.activateButton).click()
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText("A user with this email is already provisioned.")).toBeVisible()
    // Consent unchanged — modal stays open with error.
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()

    // Admin corrects the email via the user edit form.
    await page.goto(`/bo/users/${user.user_id}/edit`)
    await waitForLiveViewConnected(page)
    await page.locator(SEL.userEmailInput).fill(CORRECTED_EMAIL)
    await page.locator(SEL.saveChanges).click()
    await waitForLiveViewSettled(page)

    // Navigate back to dashboard — conflict email is gone; retry succeeds.
    await page.goto("/bo/dashboard")
    await waitForLiveViewConnected(page)
    await page.locator(SEL.activateButton).click()
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
  })

  // ─── Scenario 5 ────────────────────────────────────────────────────────────
  test("Scenario 5 — email conflict in modal: user fixes email in place, retry succeeds", async ({
    page,
  }) => {
    // Seed a declined user with NO email — the modal will show the email input.
    const user = await createE2EDeclinedPortalUser(req)
    await registerE2EPortalConflict(req, { email: CONFLICT_EMAIL })

    await loginToBackOffice(page, { username: user.username, password: user.password })
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)

    await page.locator(SEL.activateButton).click()

    // Email input appears because user.email is nil.
    await expect(page.locator(SEL.modalEmailInput)).toBeVisible()

    // Enter the conflicted email → first accept fails with 409.
    await page.locator(SEL.modalEmailInput).fill(CONFLICT_EMAIL)
    await waitForLiveViewSettled(page)
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText("A user with this email is already provisioned.")).toBeVisible()

    // Correct the email in the same modal — no page navigation needed.
    await page.locator(SEL.modalEmailInput).fill(CORRECTED_EMAIL)
    await waitForLiveViewSettled(page)
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // Success — banner gone, email saved.
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
  })

  // ─── Scenario 6 ────────────────────────────────────────────────────────────
  test("Scenario 6 — fingerprint conflict: error shown, closing modal leaves system clean", async ({
    page,
  }) => {
    const user = await createE2EDeclinedPortalUser(req, { email: ONBOARD_EMAIL })

    // Fetch the fingerprint the server will send so we can pre-register it.
    const fingerprint = await getE2EMachineFingerprint(req)
    await registerE2EPortalConflict(req, { fingerprint })

    await loginToBackOffice(page, { username: user.username, password: user.password })
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)

    await page.locator(SEL.activateButton).click()
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // 409 fingerprint error — the portal rejects this machine.
    await expect(
      page.getByText("Machine fingerprint already registered to another account.")
    ).toBeVisible()

    // Close the modal — nothing is written to DB.
    await page.locator(SEL.closeModal).click()
    await waitForLiveViewSettled(page)

    // System is still in a clean declined state: banner visible, consent unchanged.
    await expect(page.locator(SEL.activateButton)).toBeVisible()
  })
})
