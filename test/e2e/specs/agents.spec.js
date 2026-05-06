const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
  pickSearchableSelect,
  createE2EAiCredential,
  createE2EMcpEndpoint,
} = require("../support/bo")

const AGENTS_PATH = "/bo/agents"

async function openNewAgentForm(page, name) {
  await gotoBackOfficeLive(page, AGENTS_PATH)
  await page.locator('[phx-click="new_agent"]').click()
  await expect(page.locator("#configured-agent-form")).toBeVisible()
  await page.locator('input[name="configured_agent[name]"]').fill(name)
  await page.locator('textarea[name="configured_agent[job]"]').fill("Answer questions about the company.")
}

async function selectAgentCredential(page, credentialName) {
  const option = page
    .locator('select[name="configured_agent[credential_id]"] option')
    .filter({ hasText: credentialName })
    .first()

  await expect(option).toBeAttached()
  const credValue = await option.getAttribute("value")

  await page.locator('select[name="configured_agent[credential_id]"]').selectOption(credValue)
  await waitForLiveViewSettled(page)
}

async function pickFirstSearchableSelectOption(page, containerSel) {
  const trigger = page.locator(`${containerSel} [data-select-trigger]`)
  const options = page.locator(`${containerSel} [data-select-option]`)

  await trigger.click()
  await expect(options).not.toHaveCount(0)
  await options.first().click()
}

test.describe("Agents", () => {
  test.beforeEach(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test("create an agent with AI credentials", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credentialName = `E2E OpenRouter ${Date.now()}`
    const credential = await createE2EAiCredential(req, {
      name: credentialName,
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec seeded credential",
    })
    await req.dispose()
    await loginToBackOffice(page)

    // ── Step 2: create an agent using that credential ─────────────────────
    const agentName = `E2E Agent ${Date.now()}`
    await openNewAgentForm(page, agentName)
    await selectAgentCredential(page, credential.name)
    await page.locator("#configured-agent-model-select").waitFor({
      state: "visible",
      timeout: process.env.CI ? 20_000 : 10_000,
    })
    // Wait until provider models are rendered for this credential so the model
    // searchable select is stable before interacting with it.
    await expect(page.locator("#configured-agent-model-select [data-select-option]")).not.toHaveCount(
      0,
      { timeout: process.env.CI ? 20_000 : 10_000 }
    )
    await waitForLiveViewSettled(page)

    await pickSearchableSelect(page, "#configured-agent-model-select", "openai/gpt-5.1-chat")

    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    // ── Step 3: agent is saved ────────────────────────────────────────────
    await expect(page.getByText("Agent created")).toBeVisible()
    await expect(page.getByText(agentName)).toBeVisible()
  })

  test("add tools and MCP endpoint for a tool-capable model", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await createE2EAiCredential(req, {
      name: `E2E OpenRouter ${Date.now()}`,
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec seeded credential",
    })
    const mcpName = `E2E MCP ${Date.now()}-${Math.floor(Math.random() * 10000)}`
    const mcp = await createE2EMcpEndpoint(req, {
      name: mcpName,
      type: "local",
      status: "enabled",
      timeout_ms: 5000,
      command: "echo",
      args: [],
      environments: {},
      secret_environments: {},
      headers: {},
      secret_headers: {},
      settings: {},
    })
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent Tools MCP ${Date.now()}`)
    await selectAgentCredential(page, credential.name)

    await page.locator("#configured-agent-model-select").waitFor({ state: "visible" })
    await expect(page.locator("#configured-agent-model-select [data-select-option]")).not.toHaveCount(0)
    await pickSearchableSelect(page, "#configured-agent-model-select", "openai/gpt-5.1-chat")
    await waitForLiveViewSettled(page)
    await expect(page.locator("#add-tools-button")).toBeEnabled()
    await expect(page.locator("#add-mcp-button")).toBeEnabled()

    await page.locator("#add-tools-button").click()
    await expect(page.locator("#agent-tools-picker-modal")).toBeVisible()
    await pickFirstSearchableSelectOption(page, "#agent-tools-picker-select")
    await waitForLiveViewSettled(page)
    await expect(page.locator("[data-selected-tool-key]")).not.toHaveCount(0)
    await page.locator("#agent-tools-picker-modal").getByRole("button").first().click()
    await expect(page.locator("#agent-tools-picker-modal")).not.toBeVisible()
    await waitForLiveViewSettled(page)

    await page.locator("#add-mcp-button").click()
    await expect(page.locator("#agent-mcp-picker-modal")).toBeVisible()
    await pickSearchableSelect(page, "#agent-mcp-picker-select", `${mcp.name} (#${mcp.id})`)
    await waitForLiveViewSettled(page)
    await page.locator("#agent-mcp-picker-modal").getByRole("button").first().click()
    await expect(page.locator("#agent-mcp-picker-modal")).not.toBeVisible()
    await expect(
      page.locator(`[data-selected-mcp-endpoint-id="${mcp.id}"]`)
    ).toBeVisible()
  })

  test("custom model shows tool-calling warning and disables MCP/tools actions", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await createE2EAiCredential(req, {
      name: `E2E Custom ${Date.now()}`,
      provider: "Custom",
      endpoint: "https://custom-endpoint.com",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec seeded credential",
    })
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent Custom ${Date.now()}`)
    await selectAgentCredential(page, credential.name)

    const modelInput = page.locator('input[name="configured_agent[model]"]')
    await expect(modelInput).toBeVisible()
    await modelInput.fill("unsupported-model-no-tools")
    await modelInput.press("Tab")
    await waitForLiveViewSettled(page)

    await expect(
      page.getByText(
        "Selected model does not support tool calling. MCP endpoints and tools are unavailable for this model."
      )
    ).toBeVisible()
    await expect(page.locator("#add-mcp-button")).toBeDisabled()
    await expect(page.locator("#add-tools-button")).toBeDisabled()
  })
})
