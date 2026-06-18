const { test, expect } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

const NEW_USER_PATH = "/bo/users/new"

test.describe("BO user form", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request)
    await loginToBackOffice(page)
  })

  test("new user password field shows policy requirements checklist when typing", async ({ page }) => {
    await gotoBackOfficeLive(page, NEW_USER_PATH)

    await expect(page.getByRole("heading", { name: "Create a new user" })).toBeVisible()

    const passwordInput = page.locator("#user-password")
    await passwordInput.fill("Short1!")
    await passwordInput.blur()
    await waitForLiveViewSettled(page)
    await page.waitForTimeout(400)

    const panel = page.locator("#password-requirements")
    await expect(panel).toBeVisible()
    await expect(panel.getByText("Password Requirements")).toBeVisible()
    await expect(page.locator('[id^="password-requirement-"]').first()).toBeVisible()
  })
})
