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
  getE2EZAQRouterCredential,
} = require("../support/bo")

const AGENTS_PATH = "/bo/agents"

// ZAQ Router is provisioned by the E2E support path and advertises deterministic
// tool-capable models, unlike external provider catalogs.
const TOOL_MODEL = "openai/gpt-oss-120b"
const VISION_MODEL = "qwen/qwen3-vl-235b-a22b-instruct"

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

async function getZaqRouterCredential(req) {
  const credential = await getE2EZAQRouterCredential(req, { withApiKey: true })
  expect(credential.found).toBeTruthy()
  expect(credential.name).toBe("ZAQ Router")
  expect(credential.has_api_key).toBeTruthy()
  return credential
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

  test("model modalities update with the credential and model in the create form", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    const custom = await createE2EAiCredential(page, {
      name: "E2E Custom Modalities",
      provider: "Custom",
      endpoint: "https://custom-endpoint.com",
      api_key: "e2e-modality-key",
    })

    const agentName = "E2E Agent Modalities"
    await openNewAgentForm(page, agentName)
    const modalities = page.locator("#agent-form-modalities")
    await expect(modalities).toHaveText("Select a model to view modalities")
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, VISION_MODEL)

    await expect(modalities.getByRole("button", { name: "Input: Image", exact: true })).toBeVisible()
    expect(await modalities.locator("button").evaluateAll(buttons => buttons.map(b => b.getAttribute("aria-label"))))
      .toEqual(["Input: Text", "Input: Image", "Output: Text"])

    const image = modalities.getByRole("button", { name: "Input: Image", exact: true })
    const tooltip = page.locator(`[id="${await image.getAttribute("aria-describedby")}"]`)
    await image.hover()
    await expect(tooltip).toBeVisible()
    await expect(tooltip).toHaveText("Input: Image")
    await page.mouse.move(0, 0)
    await expect(tooltip).toBeHidden()
    await image.focus()
    await expect(tooltip).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(tooltip).toBeHidden()
    await expect(page.locator("#configured-agent-form")).toBeVisible()

    const arrowColor = await modalities.locator(".zaq-model-modalities-arrow").evaluate(el => getComputedStyle(el).color)
    const iconColor = await image.evaluate(el => getComputedStyle(el).color)
    expect(arrowColor).not.toBe(iconColor)

    await selectModelFromPicker(page, TOOL_MODEL)
    await expect(modalities.getByRole("button", { name: "Input: Unknown", exact: true })).toBeVisible()
    await expect(modalities.getByRole("button", { name: "Output: Unknown", exact: true })).toBeVisible()
    await selectModelFromPicker(page, VISION_MODEL)
    await expect(image).toBeVisible()

    await selectAgentCredential(page, custom.name)
    await expect(modalities.getByRole("button", { name: "Input: Unknown", exact: true })).toBeVisible()
    await expect(modalities.getByRole("button", { name: "Output: Unknown", exact: true })).toBeVisible()
    await expect(modalities.getByRole("button", { name: "Input: Image", exact: true })).toHaveCount(0)

    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, VISION_MODEL)
    await expect(modalities.getByRole("button", { name: "Input: Image", exact: true })).toBeVisible()
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    const row = page.locator("#agents-table tr").filter({ hasText: agentName })
    await expect(row.getByRole("button", { name: "Input: Image", exact: true })).toBeVisible()
    await expect(row.getByRole("button", { name: "Output: Text", exact: true })).toBeVisible()
  })

  test("list modalities stay beside the model and tooltips do not select the row", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 1000 })
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
    const agent = await createE2EAgent(req, {
      name: "E2E Vision Modalities",
      job: "Answer with text.",
      model: VISION_MODEL,
      credential_id: credential.id,
    })
    const unknown = await createE2EAgent(req, {
      name: "E2E Unknown Modalities",
      job: "Unknown catalog entry.",
      model: "unlisted-custom-model",
      credential_id: credential.id,
    })
    await req.dispose()
    await loginToBackOffice(page)
    await gotoBackOfficeLive(page, AGENTS_PATH)

    const row = page.locator(`#agent-row-${agent.id}`)
    const modalities = row.locator(".zaq-model-modalities")
    const image = modalities.getByRole("button", { name: "Input: Image", exact: true })
    const tooltip = page.locator(`[id="${await image.getAttribute("aria-describedby")}"]`)
    await image.click()
    await expect(tooltip).toBeVisible()
    await expect(tooltip).toHaveText("Input: Image")
    await expect(page.locator("#agent-form-drawer")).toHaveCount(0)
    await tooltip.click()
    await expect(page.locator("#agent-form-drawer")).toHaveCount(0)
    await expect(tooltip).toBeVisible()
    await page.keyboard.press("Escape")
    await expect(tooltip).toBeHidden()

    const modelBox = await row.getByText(VISION_MODEL, { exact: true }).boundingBox()
    const iconsBox = await modalities.boundingBox()
    expect(iconsBox.x).toBeGreaterThanOrEqual(modelBox.x + modelBox.width)
    expect(Math.abs(iconsBox.y + iconsBox.height / 2 - modelBox.y - modelBox.height / 2)).toBeLessThan(2)

    const unknownModalities = page.locator(`#agent-${unknown.id}-modalities`)
    await expect(unknownModalities.getByRole("button", { name: "Input: Unknown", exact: true })).toBeVisible()
    await expect(unknownModalities.getByRole("button", { name: "Output: Unknown", exact: true })).toBeVisible()

    await row.getByText(agent.name, { exact: true }).click()
    await expect(page.locator("#agent-form-modalities").getByRole("button", { name: "Input: Image", exact: true })).toBeVisible()
    await page.locator("#close-agent-detail").click()
    await page.locator('input[name="filters[name]"]').fill(agent.name)
    await waitForLiveViewSettled(page)
    await expect(page.locator(`#agent-row-${unknown.id}`)).toHaveCount(0)
    await expect(image).toBeVisible()
  })

  test.describe("modality touch tooltips and responsive layout", () => {
    test.use({ hasTouch: true, viewport: { width: 1440, height: 1100 } })

    test("equal-width desktop fields stack on mobile and icons respond to taps", async ({ page }) => {
      const req = await apiRequest.newContext()
      const credential = await getZaqRouterCredential(req)
      const agent = await createE2EAgent(req, {
        name: "E2E Touch Modalities",
        job: "Answer with text.",
        model: VISION_MODEL,
        credential_id: credential.id,
      })
      await req.dispose()
      await loginToBackOffice(page)
      await gotoBackOfficeLive(page, AGENTS_PATH)

      const row = page.locator(`#agent-row-${agent.id}`)
      const listIcon = row.getByRole("button", { name: "Input: Image", exact: true })
      await listIcon.tap()
      await expect(row.locator('[role="tooltip"]:visible')).toHaveText("Input: Image")
      await expect(page.locator("#agent-form-drawer")).toHaveCount(0)
      await row.locator('[role="tooltip"]:visible').tap()
      await expect(page.locator("#agent-form-drawer")).toHaveCount(0)
      await expect(row.locator('[role="tooltip"]:visible')).toHaveText("Input: Image")

      await row.getByText(agent.name, { exact: true }).click()
      await expect(page.locator("#agent-form-modalities")).toBeVisible()
      const credentialField = page.locator('select[name="configured_agent[credential_id]"]')
      const modelField = page.locator("#configured-agent-model-select")
      const modalities = page.locator("#agent-form-modalities")
      const credentialBox = await credentialField.boundingBox()
      const modelBox = await modelField.boundingBox()
      const iconsBox = await modalities.boundingBox()
      expect(Math.abs(credentialBox.width - modelBox.width)).toBeLessThan(1)
      expect(Math.abs(credentialBox.y - modelBox.y)).toBeLessThan(1)
      expect(iconsBox.x).toBeGreaterThanOrEqual(modelBox.x + modelBox.width)
      expect(iconsBox.y + iconsBox.height).toBeLessThanOrEqual(credentialBox.y + credentialBox.height)

      await page.setViewportSize({ width: 390, height: 844 })
      const mobileCredential = await credentialField.boundingBox()
      const mobileModel = await modelField.boundingBox()
      const mobileIcons = await modalities.boundingBox()
      expect(mobileModel.y).toBeGreaterThanOrEqual(mobileCredential.y + mobileCredential.height)
      expect(mobileIcons.x).toBeGreaterThanOrEqual(mobileModel.x + mobileModel.width)
      expect(mobileIcons.y).toBeLessThan(mobileModel.y + mobileModel.height)
      const mobileModelRow = await page.locator(".zaq-ai-model-row").boundingBox()
      expect(Math.abs(mobileCredential.width - mobileModelRow.width)).toBeLessThan(1)

      await modalities.getByRole("button", { name: "Input: Image", exact: true }).tap()
      const tooltip = modalities.locator('[role="tooltip"]:visible')
      await expect(tooltip).toHaveText("Input: Image")
      const tooltipBox = await tooltip.boundingBox()
      expect(tooltipBox.x).toBeGreaterThanOrEqual(0)
      expect(tooltipBox.x + tooltipBox.width).toBeLessThanOrEqual(390)
      expect(tooltipBox.y).toBeGreaterThanOrEqual(0)
      expect(tooltipBox.y + tooltipBox.height).toBeLessThanOrEqual(844)
      await page.locator("#configured-agent-form").getByText("Model", { exact: true }).tap()
      await expect(tooltip).toBeHidden()
    })

    test("tooltips follow partially visible icons and hide beyond drawer and horizontal clipping", async ({ page }) => {
      const req = await apiRequest.newContext()
      const credential = await getZaqRouterCredential(req)
      const agent = await createE2EAgent(req, {
        name: "E2E Clipped Modalities",
        job: "Answer with text.",
        model: VISION_MODEL,
        credential_id: credential.id,
      })
      await req.dispose()
      await loginToBackOffice(page)
      await gotoBackOfficeLive(page, AGENTS_PATH)
      await page.locator(`#agent-row-${agent.id}`).getByText(agent.name, { exact: true }).click()
      await page.setViewportSize({ width: 390, height: 844 })
      // Expand the real form so there is enough content below the modalities
      // to scroll the trigger past the drawer header without a layout fixture.
      await page.locator("#configured-agent-form summary").click()

      const modalities = page.locator("#agent-form-modalities")
      const image = modalities.getByRole("button", { name: "Input: Image", exact: true })
      const tooltip = modalities.getByRole("tooltip", { includeHidden: true }).filter({ hasText: "Input: Image" })
      const body = page.locator("#agent-form-drawer .zaq-drawer-body")
      await image.tap()
      await expect(tooltip).toBeVisible()

      // Keep half the trigger visible at the scrollport's top edge.
      await image.evaluate(el => {
        const body = el.closest(".zaq-drawer-body")
        const rect = el.getBoundingClientRect()
        body.scrollTop += rect.top + rect.height / 2 - body.getBoundingClientRect().top - body.clientTop
      })
      await expect(tooltip).toBeVisible()
      // Sample visibility and geometry together: scroll events can hide the
      // popover after toBeVisible() but before a separate boundingBox() call.
      await expect.poll(() => image.evaluate(el => {
        const tooltip = document.getElementById(el.getAttribute("aria-describedby"))
        const body = el.closest(".zaq-drawer-body")
        if (!tooltip || !body) return Infinity

        const tip = tooltip.getBoundingClientRect()
        const scrollport = body.getBoundingClientRect()
        const trigger = el.getBoundingClientRect()
        if (!tooltip.matches(":popover-open") ||
            getComputedStyle(tooltip).visibility !== "visible" ||
            [tip, scrollport, trigger].some(rect => rect.width <= 0 || rect.height <= 0)) {
          return Infinity
        }

        const expectedTop = scrollport.y >= tip.height + 8
          ? scrollport.y - tip.height - 8
          : trigger.y + trigger.height + 8
        return Math.abs(tip.y - expectedTop)
      })).toBeLessThan(1)

      await body.evaluate(el => { el.scrollTop += 40 })
      await expect(tooltip).toBeHidden()
      await image.tap()
      await expect(tooltip).toBeVisible()

      // A narrow overflow fixture exercises the same horizontal scrollport used
      // by the form when the catalog contains more modalities than fit.
      const container = page.locator(".zaq-ai-model-modalities")
      const text = modalities.getByRole("button", { name: "Input: Text", exact: true })
      const textTooltip = modalities.getByRole("tooltip", { includeHidden: true }).filter({ hasText: "Input: Text" })
      await container.evaluate(el => { el.style.width = "16px" })
      await text.tap()
      await expect(textTooltip).toBeVisible()
      await container.evaluate(el => { el.scrollLeft = el.scrollWidth })
      await expect(textTooltip).toBeHidden()
      await container.evaluate(el => { el.style.removeProperty("width"); el.scrollLeft = 0 })
      await image.tap()
      await expect(tooltip).toBeVisible()
      await page.keyboard.press("Escape")
      await expect(tooltip).toBeHidden()
    })
  })

  // ─── Existing tests (with model-picker fix applied) ───────────────────────

  test("create an agent with AI credentials", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
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

  test("model selection populates context window and preserves manual overrides", async ({ page }) => {
    await loginToBackOffice(page)

    const credential = await createE2EAiCredential(page, {
      name: `E2E OpenAI Context ${Date.now()}`,
      provider: "OpenAI",
      endpoint: "https://api.openai.com/v1",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec context-window credential",
    })

    await openNewAgentForm(page, `E2E Agent Context Window ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, "gpt-4.1-mini")

    const contextWindow = page.locator('input[name="configured_agent[model_max_context_tokens]"]')
    await expect(contextWindow).toHaveValue(/[1-9][0-9]+/)
    const modelDefault = await contextWindow.inputValue()

    await page.locator("#agent-advanced-options summary").click()
    await contextWindow.fill("120000")
    await page.locator('input[name="configured_agent[name]"]').fill(`E2E Agent Context Override ${Date.now()}`)
    await waitForLiveViewSettled(page)

    await expect(contextWindow).toHaveValue("120000")

    await page.locator("#reset-model-context-tokens").click()
    await waitForLiveViewSettled(page)

    await expect(contextWindow).toHaveValue(modelDefault)
  })

  test("add tools and MCP endpoint for a tool-capable model", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
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

  test("custom model shows unknown-capability notice and keeps MCP/tools actions enabled", async ({
    page,
  }) => {
    await loginToBackOffice(page)

    const credential = await createE2EAiCredential(page, {
      name: `E2E Custom ${Date.now()}`,
      provider: "Custom",
      endpoint: "https://custom-endpoint.com",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec seeded credential",
    })

    await openNewAgentForm(page, `E2E Agent Custom ${Date.now()}`)
    await selectAgentCredential(page, credential.name)

    await expect(page.locator("#configured-agent-model-select")).toHaveCount(0)
    const modelInput = page.locator('input[type="text"][name="configured_agent[model]"]')
    await expect(modelInput).toBeVisible()
    await modelInput.fill("unlisted-custom-model")
    await modelInput.press("Tab")
    await waitForLiveViewSettled(page)

    await expect(
      page.getByText(
        "Tool-calling support could not be determined for this model. Only add tools or MCP endpoints if the model supports tool calling; otherwise, requests may fail at runtime."
      )
    ).toBeVisible()
    await expect(
      page.getByText(
        "Selected model does not support tool calling. MCP endpoints and tools are unavailable for this model."
      )
    ).toHaveCount(0)
    await expect(page.locator("#add-mcp-button")).toBeEnabled()
    await expect(page.locator("#add-tools-button")).toBeEnabled()
  })

  test("confirmed unsupported model disables MCP/tools actions", async ({ page }) => {
    await loginToBackOffice(page)

    const credential = await createE2EAiCredential(page, {
      name: `E2E Unsupported ${Date.now()}`,
      provider: "OpenAI",
      endpoint: "https://api.openai.com/v1",
      api_key: `e2e-key-${Date.now()}`,
      description: "Agents spec seeded credential",
    })

    await openNewAgentForm(page, `E2E Agent Unsupported ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, "gpt-5.1-2025-11-13")
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
    await getZaqRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, '[phx-click="new_agent"]', "#configured-agent-form")
    await page.locator('input[name="configured_agent[name]"]').fill("Should Not Be Saved")

    await page.locator("#close-agent-detail").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).not.toBeVisible()
    await expect(page.getByText("Should Not Be Saved")).not.toBeVisible()
  })

  test("edit an existing agent and save updates", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
    const agent = await createE2EAgent(req, {
      name: "E2E Agent To Edit",
      job: "Original job description.",
      model: TOOL_MODEL,
      credential_id: credential.id,
    })
    await req.dispose()
    await loginToBackOffice(page)

    await gotoBackOfficeLive(page, AGENTS_PATH)
    await clickUntilVisible(page, `#agent-row-${agent.id} td:first-child`, "#configured-agent-form")
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
    const credential = await getZaqRouterCredential(req)
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
      `#agent-row-${agent.id} td:first-child`,
      `[phx-click="delete_agent"][phx-value-id="${agent.id}"]`
    )

    await page.locator(`[phx-click="delete_agent"][phx-value-id="${agent.id}"]`).click()
    await waitForLiveViewSettled(page)

    await expect(page.getByText(agent.name)).not.toBeVisible()
  })

  test("filter agents by name shows only matching agents", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
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
    const credential = await getZaqRouterCredential(req)
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
    const credential = await getZaqRouterCredential(req)
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
    const credential = await getZaqRouterCredential(req)
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
    const credential = await getZaqRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent JSON Error ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    await page.locator("#agent-advanced-options summary").click()
    await page.locator('textarea[name="configured_agent[advanced_options_json]"]').fill("{invalid json}")
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/valid JSON/i).first()).toBeVisible()
  })

  test("non-object JSON in advanced options shows inline error", async ({ page }) => {
    const req = await apiRequest.newContext()
    const credential = await getZaqRouterCredential(req)
    await req.dispose()
    await loginToBackOffice(page)

    await openNewAgentForm(page, `E2E Agent JSON Object Error ${Date.now()}`)
    await selectAgentCredential(page, credential.name)
    await selectModelFromPicker(page, TOOL_MODEL)
    await waitForLiveViewSettled(page)

    await page.locator("#agent-advanced-options summary").click()
    await page.locator('textarea[name="configured_agent[advanced_options_json]"]').fill('"just a string"')
    await page.locator("#save-agent-button").click()
    await waitForLiveViewSettled(page)

    await expect(page.locator("#configured-agent-form")).toBeVisible()
    await expect(page.getByText(/must be a JSON object/i).first()).toBeVisible()
  })
})
