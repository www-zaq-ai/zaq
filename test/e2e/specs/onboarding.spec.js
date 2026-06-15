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
  getE2EZAQRouterCredential,
} = require("../support/bo")

// Onboarding E2E — covers all 6 critical scenarios end-to-end.
//
// Bootstrap scenarios (1–3): user lands on /bo/change-password, sets email +
// password, then makes a portal consent decision. State is seeded via the E2E
// API; the portal loopback stub at /e2e/portal/* handles all portal calls.
//
// Dashboard retry scenarios (4–6): user has already completed bootstrap with
// portal_consent="declined" and is retrying from the dashboard banner.
//
// Post-accept flow: accepting consent now shows a post-accept modal before any
// redirect. The user must click "Got it" to proceed to the destination page.
// Bootstrap accept → Got it → /bo/ingestion.
// Dashboard retry accept → Got it → modal closes, stays on dashboard.

const STRONG_PASSWORD = "StrongPass1!"
const ONBOARD_EMAIL = "fresh.admin@e2e.local"
const CONFLICT_EMAIL = "already-taken@e2e.local"
const CORRECTED_EMAIL = "corrected.admin@e2e.local"

const POST_ACCEPT = {
  title: "Activation email has been sent",
  mainMessage: "Verify your email within 4 hours to keep using your free credits",
  secondaryMessage: "You have the option to change your email address in your user account",
}

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

  // Post-accept modal ("Activation email has been sent")
  gotItButton: 'button:has-text("Got it")',

  // Dashboard retry banner
  activateButton: 'button:has-text("Activate")',

  // User edit form (/bo/users/:id/edit)
  userEmailInput: 'input[name="user[email]"]',
  saveChanges: 'button:has-text("Save Changes")',

}

// Assert all three post-accept modal fields are visible.
async function verifyPostAcceptModal(page) {
  await expect(page.getByText(POST_ACCEPT.title)).toBeVisible()
  await expect(page.getByText(POST_ACCEPT.mainMessage)).toBeVisible()
  await expect(page.getByText(POST_ACCEPT.secondaryMessage)).toBeVisible()
}

// Verify ZAQ Router credential state via the E2E API — bypasses the UI to
// avoid LiveView form interaction issues. Asserts the credential exists and
// whether it has an API key (hasApiKey=true) or is keyless (hasApiKey=false).
async function verifyZAQRouter(req, { hasApiKey }) {
  const data = await getE2EZAQRouterCredential(req)
  expect(data.found).toBe(true)
  expect(data.has_api_key).toBe(hasApiKey)
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
    // Filling fields one-by-one moves focus between them, triggering blur events
    // that flush phx-debounce="300" with partial state (e.g. password="" when
    // only email has been typed). The server patches those fields back to "" and
    // intermediate phx-change responses race with Playwright's subsequent fills.
    //
    // Fix: fill the fields (accepting the intermediate events), then restore all
    // three values atomically via the native DOM setter (no focus change = no new
    // phx-change debounce) and submit via requestSubmit() in a single evaluate
    // call. requestSubmit() bypasses the disabled button (stale passwords_match?)
    // and triggers the HTML5 required check against the values we just set.
    await page.locator(SEL.email).fill(ONBOARD_EMAIL)
    await page.locator(SEL.password).fill(STRONG_PASSWORD)
    await page.locator(SEL.passwordConfirmation).fill(STRONG_PASSWORD)
    await page.locator(SEL.passwordConfirmation).blur()
    await waitForLiveViewSettled(page)

    await page.evaluate(([emailVal, pwVal, emailSel, pwSel, confirmSel]) => {
      const nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set
      function fill(sel, val) {
        const el = document.querySelector(sel)
        if (el) nativeSetter.call(el, val)
      }
      fill(emailSel, emailVal)
      fill(pwSel, pwVal)
      fill(confirmSel, pwVal)
      document.querySelector("#change-password-form").requestSubmit()
    }, [ONBOARD_EMAIL, STRONG_PASSWORD, SEL.email, SEL.password, SEL.passwordConfirmation])

    await waitForLiveViewSettled(page)
  }

  // ─── Scenario 1 ────────────────────────────────────────────────────────────
  test("Scenario 1 — portal unreachable: skips modal, shows offline notice on dashboard", async ({
    page,
  }) => {
    // Make the portal stub return 503 — client treats it as :unavailable.
    await setE2EPortalOffline(req, true)
    await setupBootstrapUser(page)

    // Submit form — no modal will appear (portal_reachable: false at mount).
    await fillBootstrapForm(page)

    // Redirects directly to dashboard with the standard flash.
    await expect(page).toHaveURL(/\/bo\/dashboard/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)
    await expect(page.getByText("Password changed successfully")).toBeVisible()

    // Dashboard shows the offline notice; the retry banner is absent.
    await expect(
      page.getByText("ZAQ portal is not reachable in this environment")
    ).toBeVisible()
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
  })

  // ─── Scenario 2 ────────────────────────────────────────────────────────────
  test("Scenario 2 — accept at bootstrap: post-accept modal shown, Got it redirects to ingestion", async ({
    page,
  }) => {
    await setupBootstrapUser(page)
    await fillBootstrapForm(page)

    // Modal appears — accept the offer.
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await expect(page.getByText("Activate your free credits")).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // Post-accept modal appears before the redirect — verify all content fields.
    await verifyPostAcceptModal(page)

    // Got it → flash + navigate to ingestion.
    await page.locator(SEL.gotItButton).click()
    await expect(page).toHaveURL(/\/bo\/ingestion/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)
    await expect(page.getByText("drop your files to bring your company brain to life")).toBeVisible()

    // Dashboard must not show the retry banner.
    await page.goto("/bo/dashboard")
    await waitForLiveViewConnected(page)
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
    await expect(page.getByText("Activate your free credits")).toHaveCount(0)

    // ZAQ Router credential must be present with an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
  })

  // ─── Scenario 7 ────────────────────────────────────────────────────────────
  test("Scenario 7 — accept at bootstrap: ZAQ Router credential present with API key", async ({
    page,
  }) => {
    await setupBootstrapUser(page)
    await fillBootstrapForm(page)

    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // Post-accept modal — verify content and dismiss.
    await verifyPostAcceptModal(page)
    await page.locator(SEL.gotItButton).click()
    await expect(page).toHaveURL(/\/bo\/ingestion/, { timeout: 10_000 })

    // ZAQ Router must be present with an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
  })

  // ─── Scenario 8 ────────────────────────────────────────────────────────────
  test("Scenario 8 — decline at bootstrap: ZAQ Router credential present in system config (keyless)", async ({
    page,
  }) => {
    await setupBootstrapUser(page)
    await fillBootstrapForm(page)

    await expect(page.locator(SEL.declineConsent)).toBeVisible()
    await page.locator(SEL.declineConsent).click()
    await expect(page).toHaveURL(/\/bo\/dashboard/, { timeout: 10_000 })
    await waitForLiveViewConnected(page)

    // ZAQ Router must be scaffolded even though the user declined — but keyless.
    await verifyZAQRouter(req, { hasApiKey: false })
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

    // Post-accept modal appears — verify content and dismiss.
    await verifyPostAcceptModal(page)
    await page.locator(SEL.gotItButton).click()
    await waitForLiveViewSettled(page)

    // Banner disappears — consent accepted, credential provisioned.
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)
    await expect(page.getByText("Activate your free credits")).toHaveCount(0)

    // ZAQ Router credential must now have an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
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

    // Post-accept modal appears — verify content and dismiss.
    await verifyPostAcceptModal(page)
    await page.locator(SEL.gotItButton).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator(SEL.activateButton)).toHaveCount(0)

    // ZAQ Router credential must have an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
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

    // Post-accept modal appears — verify content and dismiss.
    await verifyPostAcceptModal(page)
    await page.locator(SEL.gotItButton).click()
    await waitForLiveViewSettled(page)

    // Success — banner gone.
    await expect(page.locator(SEL.activateButton)).toHaveCount(0)

    // ZAQ Router credential must have an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
  })

  // ─── Scenario 9 ────────────────────────────────────────────────────────────
  test("Scenario 9 — email conflict for user with existing email: modal reveals inline email input on 409", async ({
    page,
  }) => {
    // User already has an email on file — the modal normally hides the email
    // input. A 409 from the portal must reveal it inline so the user can correct
    // the address without leaving the modal or navigating to Settings.
    const user = await createE2EDeclinedPortalUser(req, { email: CONFLICT_EMAIL })
    await registerE2EPortalConflict(req, { email: CONFLICT_EMAIL })

    await loginToBackOffice(page, { username: user.username, password: user.password })
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)

    // Open modal — email input is NOT present (user has an email on file).
    await page.locator(SEL.activateButton).click()
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await expect(page.locator(SEL.modalEmailInput)).toHaveCount(0)

    // First accept → portal returns 409 → email input is revealed inline.
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText("A user with this email is already provisioned.")).toBeVisible()
    await expect(page.locator(SEL.modalEmailInput)).toBeVisible()

    // Correct the email in the same modal and retry — provisioning succeeds.
    await page.locator(SEL.modalEmailInput).fill(CORRECTED_EMAIL)
    await waitForLiveViewSettled(page)
    await page.locator(SEL.acceptConsent).click()
    await waitForLiveViewSettled(page)

    // Post-accept modal appears — verify content and dismiss.
    await verifyPostAcceptModal(page)
    await page.locator(SEL.gotItButton).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator(SEL.activateButton)).toHaveCount(0)

    // ZAQ Router credential must have an API key.
    await verifyZAQRouter(req, { hasApiKey: true })
  })
})
