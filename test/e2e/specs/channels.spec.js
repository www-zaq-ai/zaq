const { test, expect } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

const CHANNELS_INDEX = "/bo/channels"
const GOOGLE_DRIVE_PROVIDER = "/bo/channels/data_source/google_drive"

test.describe("Channels index & provider UI", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request)
    await loginToBackOffice(page)
  })

  test("channels index shows provider icon strip on category cards", async ({ page }) => {
    await gotoBackOfficeLive(page, CHANNELS_INDEX)

    await expect(page.getByRole("heading", { name: "Channels", exact: true })).toBeVisible()

    const retrievalIcons = page.locator('[data-testid="channels-index-retrieval-icons"]')
    await expect(retrievalIcons).toBeVisible()
    await expect(retrievalIcons.locator("svg")).toHaveCount(6)

    const dataSourceIcons = page.locator('[data-testid="channels-index-data-source-icons"]')
    await expect(dataSourceIcons).toBeVisible()
    await expect(dataSourceIcons.locator("svg, img")).toHaveCount(3)
  })

  test("provider page opens capabilities form_dialog and closes", async ({ page }) => {
    await gotoBackOfficeLive(page, GOOGLE_DRIVE_PROVIDER)

    await expect(page.getByRole("heading", { name: "Google Drive" })).toBeVisible()

    await page.locator('[data-testid="channel-capabilities-trigger"]').click()
    await waitForLiveViewSettled(page)

    const modal = page.locator("#capabilities-modal")
    await expect(modal).toBeVisible()
    await expect(modal.getByRole("heading", { name: "Capabilities" })).toBeVisible()

    await modal.getByRole("button", { name: "Close" }).click()
    await waitForLiveViewSettled(page)
    await expect(modal).toBeHidden()
  })

  test("provider new config flow exposes Connect credential form in modal", async ({ page }) => {
    await gotoBackOfficeLive(page, GOOGLE_DRIVE_PROVIDER)

    await page.locator("#new-config-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#config-form")).toBeVisible()

    await page.locator('[phx-click="open_new_credential"]').click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#new-credential-modal")).toBeVisible()
    await expect(page.locator("#connect-credential-form")).toBeVisible()
    await expect(page.locator('input[name="credential[name]"]')).toBeVisible()

    await page.locator("#new-credential-modal").getByRole("button", { name: "Close dialog" }).click()
    await waitForLiveViewSettled(page)
    await expect(page.locator("#new-credential-modal")).toBeHidden()
  })
})
