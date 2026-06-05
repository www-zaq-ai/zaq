const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  waitForLiveViewConnected,
  resetE2EState,
  createE2EOnboardingUser,
} = require("../support/bo")

// Bootstrap onboarding flow: a user with must_change_password lands on
// /bo/change-password, sets an email + password, then decides on the portal
// consent. Accepting provisions the "ZAQ Router" credential via the loopback
// portal stub; declining records consent and surfaces a dashboard retry banner.
//
// Each spec tests ONE page (the change-password onboarding screen). State is
// seeded via the /e2e API — no UI navigation for setup.

const STRONG_PASSWORD = "StrongPass1!"
const ONBOARD_EMAIL = "fresh.admin@zaq.local"

const SEL = {
  // Change-password / onboarding form
  form: "#change-password-form",
  email: "#email",
  password: "#password",
  passwordConfirmation: "#password-confirmation",
  submit: '#change-password-form button[type="submit"]',

  // Portal consent modal
  acceptConsent: '[phx-click="accept_portal_consent"]',
  declineConsent: '[phx-click="decline_portal_consent"]',

  // Dashboard retry banner (shown only when consent == "declined")
  portalBanner: '[phx-click="show_portal_consent"]',
}

test.describe("Bootstrap onboarding", () => {
  test.beforeEach(async ({ page }) => {
    const req = await apiRequest.newContext()
    await resetE2EState(req) // clears AI credentials so "ZAQ Router" starts absent
    const creds = await createE2EOnboardingUser(req) // must_change_password user
    await req.dispose()

    // Logging in redirects must_change_password users to /bo/change-password.
    await loginToBackOffice(page, { username: creds.username, password: creds.password })
    await expect(page).toHaveURL(/\/bo\/change-password/)
    await waitForLiveViewConnected(page)
  })

  async function fillOnboardingForm(page) {
    await page.fill(SEL.email, ONBOARD_EMAIL)
    await page.fill(SEL.password, STRONG_PASSWORD)
    await page.fill(SEL.passwordConfirmation, STRONG_PASSWORD)

    // The submit button is disabled until requirements are met and the
    // confirmation matches — wait for the server round-trip to enable it.
    await expect(page.locator(SEL.submit)).toBeEnabled()
    await page.locator(SEL.submit).click()

    // Submitting opens the portal consent modal (no page navigation).
    await expect(page.locator(SEL.acceptConsent)).toBeVisible()
    await expect(page.getByText("Activate your free credits")).toBeVisible()
  }

  test("accepting consent provisions ZAQ Router and lands on a clean dashboard", async ({
    page,
  }) => {
    await fillOnboardingForm(page)

    await page.locator(SEL.acceptConsent).click()

    // Accept -> provisioning succeeds -> consent recorded "accepted" -> dashboard.
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)
    await expect(page.getByText("Password changed successfully")).toBeVisible()

    // Consent == "accepted" means the retry banner must NOT render.
    await expect(page.locator(SEL.portalBanner)).toHaveCount(0)
  })

  test("declining consent lands on the dashboard with the activation banner", async ({
    page,
  }) => {
    await fillOnboardingForm(page)

    await page.locator(SEL.declineConsent).click()

    // Decline -> consent recorded "declined" -> dashboard shows retry banner
    // (the "Activate" button) and its offer copy from the portal stub.
    await expect(page).toHaveURL(/\/bo\/dashboard/)
    await waitForLiveViewConnected(page)

    await expect(page.locator(SEL.portalBanner)).toBeVisible()
    await expect(page.getByText("Claim your $2 in free AI credits")).toBeVisible()
  })
})
