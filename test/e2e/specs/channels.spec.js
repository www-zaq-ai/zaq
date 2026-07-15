const { test, expect } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

const CHANNELS_INDEX = "/bo/channels"
const GOOGLE_DRIVE_PROVIDER = "/bo/channels/data_source/google_drive"

// In-page title only — BOLayout also renders page_title in header as h1 (duplicate accessible name).
// data-testid lives on LiveView h1s (channels_index_live, provider_live); survives zaq-text-h1 migration on body.

// Keep in sync with @retrieval_preview / @data_source_preview in channels_index_live.ex
const CHANNEL_INDEX_RETRIEVAL_PREVIEW = ["slack", "teams", "mattermost", "discord", "telegram"]
const CHANNEL_INDEX_DATA_SOURCE_PREVIEW = ["zaq_local", "google_drive", "sharepoint"]

test.describe("Channels index & provider UI", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request)
    await loginToBackOffice(page)
  })

  test("channels index shows provider icon strip on category cards", async ({ page }) => {
    await gotoBackOfficeLive(page, CHANNELS_INDEX)
    await waitForLiveViewSettled(page)

    const pageTitle = page.getByTestId("bo-main-page-heading")
    await expect(pageTitle).toBeVisible()
    await expect(pageTitle).toHaveText("Channels")

    const retrievalIcons = page.locator('[data-testid="channels-index-retrieval-icons"]')
    await expect(retrievalIcons).toBeVisible()
    for (const id of CHANNEL_INDEX_RETRIEVAL_PREVIEW) {
      await expect(retrievalIcons.locator(`[data-channel-preview="${id}"]`)).toBeVisible()
    }

    const dataSourceIcons = page.locator('[data-testid="channels-index-data-source-icons"]')
    await expect(dataSourceIcons).toBeVisible()
    for (const id of CHANNEL_INDEX_DATA_SOURCE_PREVIEW) {
      await expect(dataSourceIcons.locator(`[data-channel-preview="${id}"]`)).toBeVisible()
    }
  })

  test("provider page opens capabilities form_dialog and closes", async ({ page }) => {
    await gotoBackOfficeLive(page, GOOGLE_DRIVE_PROVIDER)
    await waitForLiveViewSettled(page)

    await expect(page.getByTestId("bo-main-page-heading")).toHaveText("Google Drive")

    const trigger = page.locator('[data-testid="channel-capabilities-trigger"]')
    await expect(trigger).toBeVisible()
    await trigger.click()
    await waitForLiveViewSettled(page)

    const modal = page.getByRole("dialog", { name: "Capabilities" })
    await expect(modal).toBeVisible()
    await expect(modal.getByRole("heading", { name: "Capabilities" })).toBeVisible()

    await modal.getByTestId("channel-capabilities-close").click()
    await waitForLiveViewSettled(page)
    await expect(modal).toBeHidden()
  })

  test("provider new config flow exposes Connect credential form in modal", async ({ page }) => {
    await gotoBackOfficeLive(page, GOOGLE_DRIVE_PROVIDER)
    await waitForLiveViewSettled(page)

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
