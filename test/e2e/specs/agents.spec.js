const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

const AGENTS_PATH = "/bo/agents"
const CONFIG_PATH = "/bo/system-config"

test.describe("Agents", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test("create an agent with AI credentials", async ({ page }) => {
    await loginToBackOffice(page)

    // ── Step 1: create an AI credential ──────────────────────────────────
    const unique = Date.now()
    const credentialName = `E2E Cred ${unique}`

    await gotoBackOfficeLive(page, CONFIG_PATH)
    await page.locator('[phx-value-tab="ai_credentials"]').click()
    await expect(page).toHaveURL(/tab=ai_credentials/)

    await page.locator('[phx-click="new_ai_credential"]').click()
    await expect(page.locator("#ai-credential-form")).toBeVisible()

    await page.locator('input[name="ai_credential[name]"]').fill(credentialName)
    await page.locator("#ai-credential-provider-select [data-select-trigger]").click()
    await page.locator("#ai-credential-provider-select [data-select-search]").fill("openrouter")
    await page.locator('#ai-credential-provider-select [data-select-option="OpenRouter"]').click()
    // await page.locator('input[name="ai_credential[endpoint]"]').fill("http://localhost:11434/v1")
    await page.locator("#ai-credential-api-key-input").fill(`key-${unique}`)
    await page.locator("#ai-credential-form").getByRole("button", { name: "Save credential" }).click()
    await expect(page.getByText("AI credential saved.")).toBeVisible()
    await waitForLiveViewSettled(page)

    // ── Step 2: create an agent using that credential ─────────────────────
    const agentName = `E2E Agent ${unique}`

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await page.locator('[phx-click="new_agent"]').click()
    await expect(page.locator("#configured-agent-form")).toBeVisible()

    await page.locator('input[name="configured_agent[name]"]').fill(agentName)
    await page.locator('textarea[name="configured_agent[job]"]').fill("Answer questions about the company.")

    // Pick the credential from the native select
    const credValue = await page
      .locator('select[name="configured_agent[credential_id]"] option')
      .filter({ hasText: credentialName })
      .first()
      .getAttribute("value")
    await page.locator('select[name="configured_agent[credential_id]"]').selectOption(credValue)
    await waitForLiveViewSettled(page)

    // Open model searchable select and search for the model
    await page.locator('#configured-agent-model-select [data-select-trigger]').click()
    await page.locator('#configured-agent-model-select [data-select-search]').fill("openai/gpt-5.1-chat")
    await page.locator('input[name="configured_agent[model]"]').fill("openai/gpt-5.1-chat")

    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    // ── Step 3: agent is saved ────────────────────────────────────────────
    // await expect(page.locator("#flash-info")).toBeVisible()
    await expect(page.getByText("Agent created")).toBeVisible()
    await expect(page.locator(`text=${agentName}`)).toBeVisible()
  })
})
