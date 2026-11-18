const { test, expect } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  setE2ESystemConfig,
  waitForLiveViewSettled,
} = require("../support/bo")

const CHANNELS_INDEX = "/bo/channels"
const GOOGLE_DRIVE_PROVIDER = "/bo/channels/data_source/google_drive"
const TEAMS_PROVIDER = "/bo/channels/retrieval/teams"
const E2E_BASE_URL = "https://zaq.e2e.example"

// Page title and subtitle live in BOLayout header (data-testid="bo-main-page-heading" on #bo-page-title).

// Keep in sync with @retrieval_preview / @data_source_preview in channels_index_live.ex
const CHANNEL_INDEX_RETRIEVAL_PREVIEW = ["slack", "teams", "mattermost", "discord", "telegram"]
const CHANNEL_INDEX_DATA_SOURCE_PREVIEW = ["disk", "google_drive", "sharepoint"]

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

test.describe("Microsoft Teams connector", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request)
    // Teams is a webhook provider, so ZAQ refuses to save it without a public base URL.
    await setE2ESystemConfig(request, "system.global.base_url", E2E_BASE_URL)
    await loginToBackOffice(page)
  })

  test("saves a connector with Azure credentials and shows its messaging endpoint", async ({
    page,
  }) => {
    await gotoBackOfficeLive(page, TEAMS_PROVIDER)
    await waitForLiveViewSettled(page)
    await expect(page.locator("#configs-empty-state")).toContainText(
      "Add a Microsoft Teams connection to get started",
    )

    await page.locator("#new-config-button").click()
    await waitForLiveViewSettled(page)

    const form = page.locator("#config-form")
    const saveButton = page.locator('#channel-config-modal button[type="submit"][form="config-form"]')
    await expect(form.locator("#teams-app-id")).toBeVisible()
    await expect(form.locator("#teams-tenant-id")).toBeVisible()
    await expect(form.getByText("Client Secret", { exact: true })).toBeVisible()
    await expect(form.locator('input[name="form[url]"]')).toHaveCount(0)
    await expect(form.locator('input[name="form[settings][jido_chat][bot_name]"]')).toHaveCount(0)
    await expect(form.locator('input[name="form[settings][jido_chat][bot_user_id]"]')).toHaveCount(0)

    await form.locator('input[name="form[name]"]').fill("E2E Teams")
    await form.locator("#teams-app-id").fill("  11111111-2222-3333-4444-555555555555  ")
    await form.locator('input[name="form[token]"]').fill("e2e-client-secret")
    await saveButton.click()
    await waitForLiveViewSettled(page)

    await expect(form.getByText("Tenant ID is required")).toBeVisible()
    await expect(page.locator('[id^="config-card-"]')).toHaveCount(0)

    await form.locator("#teams-tenant-id").fill("contoso.onmicrosoft.com")
    await saveButton.click()
    await waitForLiveViewSettled(page)
    await expect(page.locator("#channel-config-modal")).toBeHidden()

    // Reloading proves the connector was persisted, not just rendered.
    await gotoBackOfficeLive(page, TEAMS_PROVIDER)
    await waitForLiveViewSettled(page)

    const card = page.locator('[id^="config-card-"]').filter({ hasText: "E2E Teams" })
    await expect(card).toHaveCount(1)
    const connectorId = (await card.getAttribute("id")).replace("config-card-", "")

    await page.locator(`#edit-config-${connectorId}`).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#teams-app-id")).toHaveValue("11111111-2222-3333-4444-555555555555")
    await expect(page.locator("#teams-tenant-id")).toHaveValue("contoso.onmicrosoft.com")
    await expect(page.locator("#teams-messaging-endpoint")).toHaveValue(
      `${E2E_BASE_URL}/channels/webhook/conversation/teams/${connectorId}`,
    )
  })
})
