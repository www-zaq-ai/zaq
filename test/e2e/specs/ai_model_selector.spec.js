const { test, expect } = require("@playwright/test")
const {
  createE2EAiCredential,
  createE2EAgent,
  getE2EZAQRouterCredential,
  gotoBackOfficeLive,
  loginToBackOffice,
  pickSearchableSelect,
  resetE2EState,
  setE2ESystemConfig,
  waitForLiveViewSettled,
} = require("../support/bo")

const selectors = [
  { id: "small", tab: "global", key: "global.small_model", form: "small-model-form" },
  { id: "embedding", tab: "rag", key: "embedding", form: "embedding-config-form" },
  { id: "image-to-text", tab: "rag", key: "image_to_text", form: "image-to-text-config-form" },
  { id: "translation", tab: "rag", key: "rag.translation", form: "translation-model-form" },
  { id: "rag-reranking", tab: "rag", key: "rag.reranking", form: "rag-reranking-form" },
  { id: "decision", tab: "global", key: "global.decision_model", form: "decision-model-form" },
]

async function expectModelRowLayout(selector) {
  await expect.poll(() => selector.evaluate(root => {
    const provider = root.querySelector(".zaq-ai-model-provider").getBoundingClientRect()
    const row = root.querySelector(".zaq-ai-model-row")
    const model = root.querySelector(".zaq-ai-model-field input[type='text']:not([data-select-search]), .zaq-ai-model-field [data-select-trigger]").getBoundingClientRect()
    const modalities = root.querySelector(".zaq-ai-model-modalities").getBoundingClientRect()
    const stacked = getComputedStyle(row).display !== "contents"

    return {
      beside: modalities.left >= model.right,
      aligned: modalities.top < model.bottom && modalities.bottom > model.top,
      equalWidth: !stacked || Math.abs(provider.width - row.getBoundingClientRect().width) < 1,
      providerAbove: !stacked || provider.bottom <= model.top,
      withinViewport: modalities.right <= innerWidth + 1,
    }
  })).toEqual({ beside: true, aligned: true, equalWidth: true, providerAbove: true, withinViewport: true })
}

test.describe("Shared AI model selector", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request)
    await loginToBackOffice(page)
  })

  for (const selection of selectors) {
    test(`${selection.id} supports manual custom models, inline modalities and save/reload`, async ({ page, request }) => {
      test.setTimeout(90_000)
      const credential = await createE2EAiCredential(page, {
        name: `Shared selector ${selection.id}`,
        provider: "Custom",
        endpoint: "http://localhost:11434/v1",
        api_key: "e2e-selector-key",
      })
      await setE2ESystemConfig(request, `${selection.key}.credential_id`, String(credential.id))
      await setE2ESystemConfig(request, `${selection.key}.model`, "private/original")
      await gotoBackOfficeLive(page, `/bo/system-config?tab=${selection.tab}`)

      const form = page.locator(`#${selection.form}`)
      const selector = form.locator(".zaq-ai-model-selector")
      const model = page.locator(`#${selection.id}-model-input`)
      await expect(model).toHaveValue("private/original")
      await expect(page.locator(`#${selection.id}-model-select`)).toHaveCount(0)
      await expect(selector.getByRole("button", { name: "Input: Unknown", exact: true })).toBeVisible()
      await expect(selector.getByRole("button", { name: "Output: Unknown", exact: true })).toBeVisible()

      for (const theme of ["light", "dark"]) {
        await page.getByRole("button", { name: `Use ${theme} theme`, exact: true }).click()
        for (const width of [1280, 390]) {
          await page.setViewportSize({ width, height: 900 })
          if (width === 390 && !(await page.locator("#bo-sidebar").evaluate(el => el.classList.contains("collapsed")))) {
            await page.locator("#sidebar-toggle").click()
            await expect(page.locator("#bo-main")).toHaveCSS("margin-left", "60px")
          }
          await selector.scrollIntoViewIfNeeded()
          await expectModelRowLayout(selector)
        }
      }

      await page.setViewportSize({ width: 1280, height: 900 })
      if (selection.id === "embedding") {
        await expect(model).toBeDisabled()
        await page.locator('[phx-click="unlock_embedding"]').click()
        await page.locator('[phx-click="confirm_unlock_embedding"]').click()
        await expect(model).toBeEnabled()
      }

      await model.fill("private/updated-v2")
      await model.press("Tab")
      await waitForLiveViewSettled(page)
      await form.getByRole("button", { name: /^Save .* Settings$/ }).click()
      if (selection.id === "embedding") {
        await page.locator('[phx-click="confirm_save_embedding"]').click()
      }
      await waitForLiveViewSettled(page)
      await gotoBackOfficeLive(page, `/bo/system-config?tab=${selection.tab}`)
      await expect(page.locator(`#${selection.id}-model-input`)).toHaveValue("private/updated-v2")
    })
  }

  test("agent switches between catalog and custom selection without stale modalities", async ({ page, request }) => {
    const custom = await createE2EAiCredential(page, {
      name: "Shared selector agent custom",
      provider: "Custom",
      endpoint: "http://localhost:11434/v1",
      api_key: "e2e-selector-key",
    })
    const catalog = await getE2EZAQRouterCredential(request, { withApiKey: true })
    const agent = await createE2EAgent(request, {
      name: "Shared selector agent",
      job: "Answer questions.",
      credential_id: custom.id,
      model: "private/original",
    })
    await gotoBackOfficeLive(page, "/bo/agents")
    await page.locator(`#agent-row-${agent.id}`).getByText(agent.name, { exact: true }).click()

    const selector = page.locator("#configured-agent-form .zaq-ai-model-selector")
    const provider = selector.locator('select[name="configured_agent[credential_id]"]')
    await provider.selectOption(String(catalog.id))
    await pickSearchableSelect(page, "#configured-agent-model-select", "qwen/qwen3-vl-235b-a22b-instruct")
    await expect(selector.getByRole("button", { name: "Input: Image", exact: true })).toBeVisible()
    await provider.selectOption(String(custom.id))
    const model = page.locator("#configured-agent-model-input")
    await expect(model).toBeVisible()
    await expect(selector.getByRole("button", { name: "Input: Image", exact: true })).toHaveCount(0)
    await expect(selector.getByRole("button", { name: "Input: Unknown", exact: true })).toBeVisible()

    await page.setViewportSize({ width: 390, height: 844 })
    await selector.scrollIntoViewIfNeeded()
    await expectModelRowLayout(selector)
    await model.fill("private/updated-agent")
    await model.press("Tab")
    await waitForLiveViewSettled(page)
    await page.locator("#save-agent-button").click()
    await expect(page.getByText("Agent updated", { exact: true })).toBeVisible()
    await gotoBackOfficeLive(page, "/bo/agents")
    await page.locator(`#agent-row-${agent.id}`).getByText(agent.name, { exact: true }).click()
    await expect(page.locator("#configured-agent-model-input")).toHaveValue("private/updated-agent")
  })
})
