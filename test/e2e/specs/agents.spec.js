const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
  pickSearchableSelect,
  createE2EAiCredential,
  createE2EMcpEndpoint,
  createE2EAgent,
} = require("../support/bo")

const AGENTS_PATH = "/bo/agents"

// Seed an OpenRouter credential with a known tool-capable model.
const TOOL_MODEL = "openai/gpt-5.1-chat"

// Clicks `clickSelector` and waits for `revealSelector` to appear, retrying the
// click if it lands before the LiveView channel is bound (a known connection
// race — see the same defensive pattern in `loginToBackOffice`). Without this
// the very first form-open after a fresh page load flakes intermittently.
async function clickUntilVisible(page, clickSelector, revealSelector, attempts = 3) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await page.locator(clickSelector).first().click()
    try {
      await expect(page.locator(revealSelector)).toBeVisible({ timeout: 5_000 })
      return
    } catch (error) {
      if (attempt === attempts - 1) throw error
      await page.waitForTimeout(300)
    }
  }
}

async function openNewAgentForm(page, name) {
  await gotoBackOfficeLive(page, AGENTS_PATH)
  await clickUntilVisible(page, '[phx-click="new_agent"]', "#configured-agent-form")
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

async function seedOpenRouterCredential(req) {
  return createE2EAiCredential(req, {
    name: `E2E OpenRouter ${Date.now()}`,
    provider: "OpenRouter",
    endpoint: "https://openrouter.ai/api/v1",
    api_key: `e2e-key-${Date.now()}`,
    description: "Agents spec seeded credential",
  })
}

async function selectModelFromPicker(page, modelName) {
  await page.locator("#configured-agent-model-select").waitFor({
    state: "visible",
    timeout: process.env.CI ? 20_000 : 10_000,
  })
  // Model options can populate in stages after the credential is chosen, so
  // waiting for "any option" races an incomplete list. Wait for the *specific*
  // target model to be attached before opening the picker to click it.
  await expect(
    page.locator(`#configured-agent-model-select [data-select-option="${modelName}"]`)
  ).toHaveCount(1, { timeout: process.env.CI ? 20_000 : 10_000 })
  await waitForLiveViewSettled(page)
  await pickSearchableSelect(page, "#configured-agent-model-select", modelName)
}

test.describe("Agents", () => {
  test.beforeEach(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test("agents page renders list and opens create drawer", async ({ page }) => {
    await loginToBackOffice(page)
    await gotoBackOfficeLive(page, AGENTS_PATH)
    await expect(page.locator("#agents-master-pane")).toBeVisible()
    await expect(page.locator("#agent-form-drawer")).toHaveCount(0)

    await page.locator("#new-agent-button").click()
    await expect(page.locator("#agent-form-drawer")).toBeVisible()
    await expect(page.locator("#configured-agent-form")).toBeVisible()
  })

  // ─── Existing tests (with model-picker fix applied) ───────────────────────

  test("create an agent with AI credentials", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    const agentName = `E2E Agent ${Date.now()}`
    await openNewAgentForm(page, agentName)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)

    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText(agentName)).toBeVisible()
  })

  test("add tools and MCP endpoint for a tool-capable model", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
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
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    await expect(page.locator("#add-tools-button")).toBeEnabled()
    await expect(page.locator("#add-mcp-button")).toBeEnabled()

    // Add a tool
    await page.locator("#add-tools-button").click()
    await expect(page.locator("#agent-tools-picker-modal")).toBeVisible()
    await pickFirstSearchableSelectOption(page, "#agent-tools-picker-select")
    await waitForLiveViewSettled(page)
    await expect(page.locator("[data-selected-tool-key]")).not.toHaveCount(0)
    await page.locator("#agent-tools-picker-modal").getByRole("button").first().click()
    await expect(page.locator("#agent-tools-picker-modal")).not.toBeVisible()
    await waitForLiveViewSettled(page)

    // Add an MCP endpoint
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

    await expect(page.locator("#configured-agent-model-select")).toHaveCount(0)
    const modelInput = page.locator('input[type="text"][name="configured_agent[model]"]')
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

  // ─── Phase 1: CRUD ────────────────────────────────────────────────────────

  test("cancel agent form discards changes", async ({ page }) => {
    const req = await apiRequest.newContext()
    await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, '[phx-click="new_agent"]', "#configured-agent-form")
    await page.locator('input[name="configured_agent[name]"]').fill("Should Not Be Saved")

    await page.locator('[phx-click="cancel_agent_form"]').click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).not.toBeVisible()
    await expect(page.getByText("Should Not Be Saved")).not.toBeVisible()
  })

  test("edit an existing agent and save updates", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    const agent = await createE2EAgent(req, {
      name: "E2E Agent To Edit",
      job: "Original job description.",
      model: TOOL_MODEL,
      credential_id: credential.id,
    })
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, `[phx-value-id="${agent.id}"]`, "#configured-agent-form")
    await waitForLiveViewSettled(page)

    const updatedName = `E2E Agent Edited ${Date.now()}`
    await page.locator('input[name="configured_agent[name]"]').fill(updatedName)
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText("Agent updated")).toBeVisible()
    await expect(page.getByText(updatedName)).toBeVisible()
  })

  test("delete an agent removes it from the list", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    const agent = await createE2EAgent(req, {
      name: "E2E Agent To Delete",
      job: "Will be deleted.",
      model: TOOL_MODEL,
      credential_id: credential.id,
    })
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await expect(page.getByText(agent.name)).toBeVisible()

    // Selecting the row opens the detail form (where Delete lives); retry the
    // click until the delete button appears so a patch-race select doesn't leave
    // us clicking a button that isn't rendered yet.
    await clickUntilVisible(
      page,
      `[phx-value-id="${agent.id}"]`,
      `[phx-click="delete_agent"][phx-value-id="${agent.id}"]`
    )

    await page.locator(`[phx-click="delete_agent"][phx-value-id="${agent.id}"]`).click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText(agent.name)).not.toBeVisible()
  })

  test("filter agents by name shows only matching agents", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    const agentA = await createE2EAgent(req, {
      name: "E2E FilterAlpha",
      job: "First agent.",
      model: TOOL_MODEL,
      credential_id: credential.id,
    })
    const agentB = await createE2EAgent(req, {
      name: "E2E FilterBeta",
      job: "Second agent.",
      model: TOOL_MODEL,
      credential_id: credential.id,
    })
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await expect(page.getByText(agentA.name)).toBeVisible()
    await expect(page.getByText(agentB.name)).toBeVisible()

    // Re-apply the filter until it takes: a bare `.fill()` can fire its
    // phx-change while LiveView is mid-patch, dropping the event and leaving the
    // list unfiltered. Retrying the whole clear+fill+assert absorbs that race.
    const nameFilter = page.locator('input[name="filters[name]"]')
    await expect(async () => {
      await nameFilter.fill("")
      await nameFilter.fill("FilterAlpha")
      await expect(page.getByText(agentB.name)).toHaveCount(0, { timeout: 2_000 })
    }).toPass({ timeout: 15_000 })

    await expect(page.getByText(agentA.name)).toBeVisible()
  })

  // ─── Phase 2: Tools & MCP (remove / empty picker) ────────────────────────

  test("remove a tool from the agent form", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent Remove Tool ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    // Add a tool first
    await page.locator("#add-tools-button").click()
    await expect(page.locator("#agent-tools-picker-modal")).toBeVisible()
    await pickFirstSearchableSelectOption(page, "#agent-tools-picker-select")
    await waitForLiveViewSettled(page)
    const toolBadge = page.locator("[data-selected-tool-key]").first()
    await expect(toolBadge).toBeVisible()
    const toolKey = await toolBadge.getAttribute("data-selected-tool-key")
    await page.locator("#agent-tools-picker-modal").getByRole("button").first().click()
    await expect(page.locator("#agent-tools-picker-modal")).not.toBeVisible()

    // Remove the tool
    await page.locator(`[phx-click="remove_tool"][phx-value-key="${toolKey}"]`).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("[data-selected-tool-key]")).toHaveCount(0)
  })

  test("remove an MCP endpoint from the agent form", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    const mcp = await createE2EMcpEndpoint(req, {
      name: `E2E MCP Remove ${Date.now()}`,
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

    await openNewAgentForm(page, `E2E Agent Remove MCP ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    // Add MCP
    await page.locator("#add-mcp-button").click()
    await expect(page.locator("#agent-mcp-picker-modal")).toBeVisible()
    await pickSearchableSelect(page, "#agent-mcp-picker-select", `${mcp.name} (#${mcp.id})`)
    await page.locator("#agent-mcp-picker-modal").getByRole("button").first().click()
    await expect(page.locator("#agent-mcp-picker-modal")).not.toBeVisible()
    await expect(page.locator(`[data-selected-mcp-endpoint-id="${mcp.id}"]`)).toBeVisible()

    // Remove MCP
    await page.locator(`[phx-click="remove_mcp"][phx-value-id="${mcp.id}"]`).click()
    await waitForLiveViewSettled(page)

    await expect(page.locator(`[data-selected-mcp-endpoint-id="${mcp.id}"]`)).not.toBeVisible()
  })

  // ─── Phase 3: Error handling & validation ─────────────────────────────────

  test("save fails with inline error when name is blank", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, '[phx-click="new_agent"]', "#configured-agent-form")
    await selectAgentCredential(page, credential.name)

    // Leave name blank and submit
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/can't be blank/i).first()).toBeVisible()
  })

  test("save fails with inline error when no credential selected", async ({ page }) => {
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, '[phx-click="new_agent"]', "#configured-agent-form")

    await page.locator('input[name="configured_agent[name]"]').fill("No Credential Agent")
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/can't be blank/i).first()).toBeVisible()
  })

  test("invalid JSON in advanced options shows inline error", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent JSON Error ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    await page.locator('textarea[name="configured_agent[advanced_options_json]"]').fill("{invalid json}")
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/valid JSON/i).first()).toBeVisible()
  })

  test("non-object JSON in advanced options shows inline error", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await seedOpenRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent JSON Object Error ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    await page.locator('textarea[name="configured_agent[advanced_options_json]"]').fill('"just a string"')
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/must be a JSON object/i).first()).toBeVisible()
  })
})
