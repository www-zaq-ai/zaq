const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

// At least one of the two locators becomes visible. Use in place of
// `(await a.isVisible()) || (await b.isVisible())`, which is a point-in-time
// check and returns false if neither has had time to render yet.
async function expectEitherVisible(a, b, options = {}) {
  const timeout = options.timeout || 10_000
  await Promise.race([
    a.first().waitFor({ state: "visible", timeout }),
    b.first().waitFor({ state: "visible", timeout }),
  ])
}

const CONFIG_PATH = "/bo/system-config"

// Selectors using phx-click/phx-value attributes — never rely on text position
const SEL = {
  tabTelemetry: '[phx-value-tab="telemetry"]',
  tabLLM: '[phx-value-tab="llm"]',
  tabEmbedding: '[phx-value-tab="embedding"]',
  tabImageToText: '[phx-value-tab="image_to_text"]',
  tabAICredentials: '[phx-value-tab="ai_credentials"]',

  llmForm: "#llm-config-form",
  embeddingForm: "#embedding-config-form",
  imageToTextForm: "#image-to-text-config-form",
  telemetryForm: "#telemetry-config-form",
  aiCredentialForm: "#ai-credential-form",

  unlockTrigger: '[phx-click="unlock_embedding"]',
  cancelUnlock: '[phx-click="cancel_unlock_embedding"]',
  confirmUnlock: '[phx-click="confirm_unlock_embedding"]',
  cancelSave: '[phx-click="cancel_save_embedding"]',
  confirmSave: '[phx-click="confirm_save_embedding"]',

  // Parent <label> wrappers for sr-only checkboxes — the div overlay intercepts clicks on the input
  jsonModeLabel: 'label:has(input[name="llm_config[supports_json_mode]"][type="checkbox"])',
  logprobsLabel: 'label:has(input[name="llm_config[supports_logprobs]"][type="checkbox"])',
}

// Read the numeric value of an input and return an integer guaranteed != current
async function differentDimension(page) {
  const raw = await page.locator('input[name="embedding_config[dimension]"]').inputValue()
  const current = parseInt(raw, 10) || 3584
  // Use an alternating pair so re-runs always differ from the DB
  return current === 512 ? 768 : 512
}

async function pickSearchableSelect(page, containerSel, optionLabel) {
  await page.locator(`${containerSel} [data-select-trigger]`).click()
  await page.locator(`${containerSel} [data-select-search]`).fill(optionLabel)
  await page.locator(`${containerSel} [data-select-option="${optionLabel}"]`).click()
}

async function createAiCredential(page, overrides = {}) {
  const unique = `${Date.now()}-${Math.floor(Math.random() * 10000)}`
  const credential = {
    name: overrides.name || `E2E Credential ${unique}`,
    provider: overrides.provider || "Custom",
    endpoint: overrides.endpoint || "http://localhost:11434/v1",
    apiKey: overrides.apiKey || `e2e-key-${unique}`,
    sovereign: overrides.sovereign || false,
    description: overrides.description || "E2E credential",
  }

  await page.locator(SEL.tabAICredentials).click()
  await expect(page).toHaveURL(/tab=ai_credentials/)
  await page.locator('[phx-click="new_ai_credential"]').click()
  await expect(page.locator(SEL.aiCredentialForm)).toBeVisible()

  await page.locator('input[name="ai_credential[name]"]').fill(credential.name)
  await pickSearchableSelect(page, "#ai-credential-provider-select", credential.provider)
  await page.locator('input[name="ai_credential[endpoint]"]').fill(credential.endpoint)
  await page.locator("#ai-credential-api-key-input").fill(credential.apiKey)

  if (credential.sovereign) {
    await page.locator('label:has(input[name="ai_credential[sovereign]"][type="checkbox"])').click()
  }

  await page.locator('textarea[name="ai_credential[description]"]').fill(credential.description)
  await page.locator(SEL.aiCredentialForm).getByRole("button", { name: "Save credential" }).click()

  await expect(page.getByText("AI credential saved.")).toBeVisible()
  await expect(page.locator(SEL.aiCredentialForm)).not.toBeVisible()
  // Drain any trailing phx-submit events before the caller switches tabs
  await waitForLiveViewSettled(page)

  return credential
}

test.describe("System Config", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page)
    await gotoBackOfficeLive(page, CONFIG_PATH)
  })

  // ── Tab navigation ─────────────────────────────────────────────────────

  test.describe("tab navigation", () => {
    test("default tab is Telemetry", async ({ page }) => {
      await expect(page.locator(SEL.telemetryForm)).toBeVisible()
      await expect(page.locator(SEL.llmForm)).not.toBeVisible()
      await expect(page.locator(SEL.embeddingForm)).not.toBeVisible()
      await expect(page.locator(SEL.imageToTextForm)).not.toBeVisible()
    })

    test("switching to LLM shows only LLM form and updates URL", async ({ page }) => {
      await page.locator(SEL.tabLLM).click()
      await expect(page.locator(SEL.llmForm)).toBeVisible()
      await expect(page.locator(SEL.telemetryForm)).not.toBeVisible()
      await expect(page).toHaveURL(/tab=llm/)
    })

    test("switching to Embedding shows only embedding form and updates URL", async ({ page }) => {
      await page.locator(SEL.tabEmbedding).click()
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()
      await expect(page).toHaveURL(/tab=embedding/)
    })

    test("switching to Image to Text shows only that form and updates URL", async ({ page }) => {
      await page.locator(SEL.tabImageToText).click()
      await expect(page.locator(SEL.imageToTextForm)).toBeVisible()
      await expect(page).toHaveURL(/tab=image_to_text/)
    })

    test("switching to AI Credentials shows credentials panel and updates URL", async ({ page }) => {
      await page.locator(SEL.tabAICredentials).click()
      await expect(page.getByRole("heading", { name: "AI Credentials" })).toBeVisible()
      await expect(page).toHaveURL(/tab=ai_credentials/)
    })

    test("direct URL ?tab=llm loads LLM tab", async ({ page }) => {
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=llm`)
      await expect(page.locator(SEL.llmForm)).toBeVisible()
    })

    test("direct URL ?tab=embedding loads Embedding tab", async ({ page }) => {
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=embedding`)
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()
    })

    test("direct URL ?tab=image_to_text loads Image to Text tab", async ({ page }) => {
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=image_to_text`)
      await expect(page.locator(SEL.imageToTextForm)).toBeVisible()
    })

    test("direct URL ?tab=ai_credentials loads AI Credentials tab", async ({ page }) => {
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=ai_credentials`)
      await expect(page.getByRole("heading", { name: "AI Credentials" })).toBeVisible()
    })

    test("unknown ?tab value falls back to Telemetry", async ({ page }) => {
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=nonexistent`)
      await expect(page.locator(SEL.telemetryForm)).toBeVisible()
    })
  })

  // ── LLM tab ────────────────────────────────────────────────────────────

  test.describe("LLM tab", () => {
    test.beforeAll(async () => {
      const req = await apiRequest.newContext()
      await resetE2EState(req)
      await req.dispose()
    })

    test.beforeEach(async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabLLM).click()
      await expect(page.locator(SEL.llmForm)).toBeVisible()
      // Wait for the tab's phx-click to settle so the credential dropdown is
      // fully populated before pickSearchableSelect tries to search it.
      await waitForLiveViewSettled(page)
      await pickSearchableSelect(page, "#llm-credential-select", credential.name)
      // Wait for the phx-change from credential selection to fully settle before
      // the test starts. Without this, LiveView's DOM patch can overwrite fill()
      // calls made immediately after pickSearchableSelect.
      await waitForLiveViewSettled(page, { timeout: process.env.CI ? 20_000 : 10_000 })
    })

    test("renders all required form fields", async ({ page }) => {
      await expect(page.locator("#llm-credential-select [data-select-trigger]")).toBeVisible()

      const llmModelText = page.locator('input[type="text"][name="llm_config[model]"]')
      const llmModelSelect = page.locator("#llm-model-select [data-select-trigger]")
      await expectEitherVisible(llmModelText, llmModelSelect)

      await expect(page.locator('input[name="llm_config[temperature]"]')).toBeVisible()
      await expect(page.locator('input[name="llm_config[top_p]"]')).toBeVisible()
      await expect(page.locator('input[name="llm_config[max_context_window]"]')).toBeVisible()
      await expect(page.locator('input[name="llm_config[distance_threshold]"]')).toBeVisible()
    })

    test("credential selector opens and accepts option filtering", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabLLM).click()
      await expect(page.locator(SEL.llmForm)).toBeVisible()

      await pickSearchableSelect(page, "#llm-credential-select", credential.name)
      await expect(page.locator("#llm-credential-select [data-select-label]")).toContainText(
        credential.name
      )
    })

    // NOTE: top_p default is 0.9 but the HTML input has step="0.05" (min=0.01), making 0.9 an
    // invalid step value per browser constraint validation (nearest valid: 0.86, 0.91).
    // This is a real UI bug — the default can never be saved without first adjusting top_p.
    // Tests that save must set top_p to a valid step value first.
    test("successful save shows flash message (requires valid top_p step value)", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabLLM).click()
      await pickSearchableSelect(page, "#llm-credential-select", credential.name)

      // Set top_p to 0.91 — the nearest valid value on the step grid (0.01 + n×0.05)
      await page.locator('input[name="llm_config[top_p]"]').fill("0.91")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).toBeVisible()
    })

    test("flash auto-dismisses without user interaction", async ({ page }) => {
      await page.locator('input[name="llm_config[top_p]"]').fill("0.91")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).toBeVisible()
      // Must disappear on its own — do not click dismiss
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible({ timeout: 10_000 })
    })

    // ── Validation: required fields ──────────────────────────────────────

    test("clearing model (text input) blocks save (required field)", async ({ page }) => {
      // createAiCredential always uses the Custom provider, which has no predefined
      // model list — so the model widget is always a text input here, never a select.
      const modelInput = page.locator('input[name="llm_config[model]"]')
      await expect(modelInput).toBeVisible()
      await modelInput.fill("")
      await modelInput.press("Tab")
      // Wait for the validate_llm phx-change (triggered by blur on the debounced input)
      // to fully settle. Without this, a late DOM patch from the credential selection
      // phx-change can overwrite the empty value before save — causing save to succeed.
      await waitForLiveViewSettled(page)
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    // ── Validation: numeric boundaries ───────────────────────────────────

    test("temperature below 0 is rejected", async ({ page }) => {
      const field = page.locator('input[name="llm_config[temperature]"]')
      await field.fill("-1")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    test("temperature above 2.0 is rejected", async ({ page }) => {
      const field = page.locator('input[name="llm_config[temperature]"]')
      await field.fill("2.1")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    test("temperature boundary 0.0 and 2.0 have no inline validation error", async ({ page }) => {
      const field = page.locator('input[name="llm_config[temperature]"]')

      await field.fill("0.0")
      await field.press("Tab")
      await expect(
        page.locator('p.text-red-500').filter({ hasText: /temperature/i })
      ).not.toBeVisible()

      await field.fill("2.0")
      await field.press("Tab")
      await expect(
        page.locator('p.text-red-500').filter({ hasText: /temperature/i })
      ).not.toBeVisible()
    })

    test("top_p of 0 is rejected (must be > 0)", async ({ page }) => {
      const field = page.locator('input[name="llm_config[top_p]"]')
      await field.fill("0")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    test("top_p above 1.0 is rejected", async ({ page }) => {
      const field = page.locator('input[name="llm_config[top_p]"]')
      await field.fill("1.1")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    test("max_context_window of 0 is rejected (must be > 0)", async ({ page }) => {
      const field = page.locator('input[name="llm_config[max_context_window]"]')
      await field.fill("0")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    test("distance_threshold of 0 is rejected (must be > 0)", async ({ page }) => {
      const field = page.locator('input[name="llm_config[distance_threshold]"]')
      await field.fill("0")
      await field.press("Tab")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).not.toBeVisible()
    })

    // ── Toggles ───────────────────────────────────────────────────────────
    // The checkbox is sr-only; a <div> overlay intercepts direct pointer events.
    // Click the wrapping <label> element which is the actual interactive target.

    test("JSON mode toggle changes state", async ({ page }) => {
      const checkbox = page.locator('input[name="llm_config[supports_json_mode]"][type="checkbox"]')
      const initial = await checkbox.isChecked()
      await page.locator(SEL.jsonModeLabel).click()
      await expect(checkbox).toBeChecked({ checked: !initial })
    })

    test("Logprobs toggle changes state", async ({ page }) => {
      const checkbox = page.locator('input[name="llm_config[supports_logprobs]"][type="checkbox"]')
      const initial = await checkbox.isChecked()
      await page.locator(SEL.logprobsLabel).click()
      await expect(checkbox).toBeChecked({ checked: !initial })
    })

    // ── API key persistence ───────────────────────────────────────────────

    test("changing credential saves and persists after page reload", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabLLM).click()
      await pickSearchableSelect(page, "#llm-credential-select", credential.name)

      // Set top_p to a valid step value before saving (see NOTE above)
      await page.locator('input[name="llm_config[top_p]"]').fill("0.91")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).toBeVisible()

      // Full reload — triggers mount → load_llm_form → reads from DB
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=llm`)
      await expect(page.locator(SEL.llmForm)).toBeVisible()
      await expect(page.locator("#llm-credential-select [data-select-label]")).toContainText(
        credential.name
      )
    })
  })

  // ── Embedding tab ──────────────────────────────────────────────────────

  test.describe("Embedding tab", () => {
    test.beforeEach(async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabEmbedding).click()
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()
      await waitForLiveViewSettled(page)
      await pickSearchableSelect(page, "#embedding-credential-select", credential.name)
      await waitForLiveViewSettled(page, { timeout: process.env.CI ? 20_000 : 10_000 })
    })

    test("renders all required form fields", async ({ page }) => {
      await expect(page.locator("#embedding-credential-select [data-select-trigger]")).toBeVisible()
      await expect(page.locator('input[name="embedding_config[dimension]"]')).toBeVisible()
      await expect(page.locator('input[name="embedding_config[chunk_min_tokens]"]')).toBeVisible()
      await expect(page.locator('input[name="embedding_config[chunk_max_tokens]"]')).toBeVisible()
    })

    test("credential selector opens and accepts option filtering", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabEmbedding).click()
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()

      await pickSearchableSelect(page, "#embedding-credential-select", credential.name)
      await expect(page.locator("#embedding-credential-select [data-select-label]")).toContainText(
        credential.name
      )
    })

    // ── Lock / Unlock ─────────────────────────────────────────────────────

    test("model is locked by default: unlock button present, dimension disabled", async ({ page }) => {
      await expect(page.locator(SEL.unlockTrigger)).toBeVisible()
      await expect(page.locator('input[name="embedding_config[dimension]"]')).toBeDisabled()
    })

    test("unlock modal opens on Unlock click", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      // Use heading role to avoid strict-mode violation from case-insensitive substring match on <p>
      await expect(page.getByRole("heading", { name: "Unlock Model Selection" })).toBeVisible()
      await expect(page.getByText("permanently delete all existing embeddings")).toBeVisible()
    })

    test("cancel unlock: modal closes and model stays locked", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await expect(page.getByRole("heading", { name: "Unlock Model Selection" })).toBeVisible()

      await page.locator(SEL.cancelUnlock).click()

      await expect(page.getByRole("heading", { name: "Unlock Model Selection" })).not.toBeVisible()
      await expect(page.locator(SEL.unlockTrigger)).toBeVisible()
      await expect(page.locator('input[name="embedding_config[dimension]"]')).toBeDisabled()
    })

    test("confirm unlock: modal closes, unlock button gone, dimension enabled", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()

      await expect(page.getByRole("heading", { name: "Unlock Model Selection" })).not.toBeVisible()
      await expect(page.locator(SEL.unlockTrigger)).not.toBeVisible()
      await expect(page.locator('input[name="embedding_config[dimension]"]')).not.toBeDisabled()
    })

    // NOTE: handle_params only assigns active_tab — it does NOT reload the embedding form.
    // Only a full page navigation (mount) resets embedding_locked to true.
    test("full page reload re-engages the lock after it was unlocked", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()
      await expect(page.locator(SEL.unlockTrigger)).not.toBeVisible()

      // Full reload — triggers mount → load_embedding_form → embedding_locked: true
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=embedding`)

      await expect(page.locator(SEL.unlockTrigger)).toBeVisible()
      await expect(page.locator('input[name="embedding_config[dimension]"]')).toBeDisabled()
    })

    // ── Save without model change ─────────────────────────────────────────
    // NOTE: Changing endpoint while locked triggers phx-change, which excludes the disabled
    // model input from params → params["model"] = nil ≠ saved_model → model_changed = true.
    // To test a genuinely non-destructive save, submit without triggering phx-change.

    test("saving with current config (no field change) succeeds without confirm modal", async ({ page }) => {
      // model_changed is false at mount; no phx-change fired → goes straight to do_save_embedding
      await page.getByRole("button", { name: "Save Embedding Settings" }).click()

      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).not.toBeVisible()
      await expect(page.getByText("Embedding settings saved.")).toBeVisible()
    })

    // ── Destructive save flow ─────────────────────────────────────────────

    test("changing dimension after unlock marks save button red and triggers confirm modal", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()

      const dimInput = page.locator('input[name="embedding_config[dimension]"]')
      const newDim = await differentDimension(page)
      await dimInput.fill(String(newDim))
      await dimInput.press("Tab")

      const saveBtn = page.getByRole("button", { name: "Save Embedding Settings" })
      // Wait for server to process validate_embedding and set model_changed: true
      await expect(saveBtn).toHaveClass(/bg-red-500/)

      await saveBtn.click()
      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).toBeVisible()
      await expect(page.getByText("This cannot be undone")).toBeVisible()
    })

    test("cancel destructive save: modal closes, form intact, no success flash", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()

      const dimInput = page.locator('input[name="embedding_config[dimension]"]')
      const newDim = await differentDimension(page)
      await dimInput.fill(String(newDim))
      await dimInput.press("Tab")

      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).toBeVisible()

      await page.locator(SEL.cancelSave).click()

      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).not.toBeVisible()
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()
      await expect(page.getByText("Embedding settings saved.")).not.toBeVisible()
    })

    test("confirm destructive save: modal closes and save succeeds", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()

      const dimInput = page.locator('input[name="embedding_config[dimension]"]')
      const newDim = await differentDimension(page)
      await dimInput.fill(String(newDim))
      await dimInput.press("Tab")

      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).toBeVisible()

      await page.locator(SEL.confirmSave).click()

      await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).not.toBeVisible()
      await expect(page.getByText("Embedding settings saved.")).toBeVisible()
    })

    // ── Validation: required & numeric ───────────────────────────────────

    test("dimension of 0 is rejected after unlock", async ({ page }) => {
      await page.locator(SEL.unlockTrigger).click()
      await page.locator(SEL.confirmUnlock).click()

      const dimInput = page.locator('input[name="embedding_config[dimension]"]')
      await dimInput.fill("0")
      await dimInput.press("Tab")
      await page.getByRole("button", { name: "Save Embedding Settings" }).click()

      // If the confirm modal appears (model_changed = true), proceed through it
      const modal = page.getByRole("heading", { name: "Delete All Embeddings?" })
      if (await modal.isVisible()) {
        await page.locator(SEL.confirmSave).click()
      }
      await expect(page.getByText("Embedding settings saved.")).not.toBeVisible()
    })

    test("chunk_min_tokens equal to chunk_max_tokens shows order error", async ({ page }) => {
      const minInput = page.locator('input[name="embedding_config[chunk_min_tokens]"]')
      const maxInput = page.locator('input[name="embedding_config[chunk_max_tokens]"]')

      await minInput.fill("500")
      await minInput.press("Tab")
      await maxInput.fill("500")
      await maxInput.press("Tab")

      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByText("must be greater than min tokens")).toBeVisible()
      await expect(page.getByText("Embedding settings saved.")).not.toBeVisible()
    })

    test("chunk_min_tokens greater than chunk_max_tokens shows order error", async ({ page }) => {
      const minInput = page.locator('input[name="embedding_config[chunk_min_tokens]"]')
      const maxInput = page.locator('input[name="embedding_config[chunk_max_tokens]"]')

      await minInput.fill("900")
      await minInput.press("Tab")
      await maxInput.fill("400")
      await maxInput.press("Tab")

      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByText("must be greater than min tokens")).toBeVisible()
      await expect(page.getByText("Embedding settings saved.")).not.toBeVisible()
    })

    test("chunk_min_tokens of 0 is rejected (must be > 0)", async ({ page }) => {
      const minInput = page.locator('input[name="embedding_config[chunk_min_tokens]"]')
      await minInput.fill("0")
      await minInput.press("Tab")
      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByText("Embedding settings saved.")).not.toBeVisible()
    })

    // ── API key persistence ───────────────────────────────────────────────

    test("changing credential saves and persists after page reload", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabEmbedding).click()
      await pickSearchableSelect(page, "#embedding-credential-select", credential.name)

      await page.getByRole("button", { name: "Save Embedding Settings" }).click()
      await expect(page.getByText("Embedding settings saved.")).toBeVisible()

      // Full reload — triggers mount → load_embedding_form → reads from DB
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=embedding`)
      await expect(page.locator(SEL.embeddingForm)).toBeVisible()
      await expect(
        page.locator("#embedding-credential-select [data-select-label]")
      ).toContainText(credential.name)
    })
  })

  // ── Image to Text tab ──────────────────────────────────────────────────

  test.describe("Image to Text tab", () => {
    test.beforeEach(async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabImageToText).click()
      await expect(page.locator(SEL.imageToTextForm)).toBeVisible()
      await waitForLiveViewSettled(page)
      await pickSearchableSelect(page, "#image-to-text-credential-select", credential.name)
      await waitForLiveViewSettled(page, { timeout: process.env.CI ? 20_000 : 10_000 })
    })

    test("renders credential and model fields", async ({ page }) => {
      await expect(page.locator("#image-to-text-credential-select [data-select-trigger]")).toBeVisible()

      const textInput = page.locator('input[type="text"][name="image_to_text_config[model]"]')
      const dropdown = page.locator("#image-to-text-model-select [data-select-trigger]")
      await expectEitherVisible(textInput, dropdown)
    })

    test("credential selector opens and accepts option filtering", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabImageToText).click()
      await expect(page.locator(SEL.imageToTextForm)).toBeVisible()

      await pickSearchableSelect(page, "#image-to-text-credential-select", credential.name)
      await expect(
        page.locator("#image-to-text-credential-select [data-select-label]")
      ).toContainText(credential.name)
    })

    test("successful save shows flash message", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabImageToText).click()
      await pickSearchableSelect(page, "#image-to-text-credential-select", credential.name)

      await page.getByRole("button", { name: "Save Image to Text Settings" }).click()
      await expect(page.getByText("Image-to-Text settings saved.")).toBeVisible()
    })

    test("either model text input or model dropdown is present", async ({ page }) => {
      const textInput = page.locator('input[name="image_to_text_config[model]"]')
      const dropdown = page.locator("#image-to-text-model-select")
      await expectEitherVisible(textInput, dropdown)
    })

    // ── API key persistence ───────────────────────────────────────────────

    test("changing credential saves and persists after page reload", async ({ page }) => {
      const credential = await createAiCredential(page)
      await page.locator(SEL.tabImageToText).click()
      await pickSearchableSelect(page, "#image-to-text-credential-select", credential.name)

      await page.getByRole("button", { name: "Save Image to Text Settings" }).click()
      await expect(page.getByText("Image-to-Text settings saved.")).toBeVisible()

      // Full reload — triggers mount → load_image_to_text_form → reads from DB
      await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=image_to_text`)
      await expect(page.locator(SEL.imageToTextForm)).toBeVisible()
      await expect(
        page.locator("#image-to-text-credential-select [data-select-label]")
      ).toContainText(credential.name)
    })
  })

  // ── AI Credentials tab ─────────────────────────────────────────────────

  test.describe("AI Credentials tab", () => {
    test.beforeEach(async ({ page }) => {
      await page.locator(SEL.tabAICredentials).click()
      await expect(page).toHaveURL(/tab=ai_credentials/)
      await expect(page.getByRole("heading", { name: "AI Credentials" })).toBeVisible()
    })

    test("create credential shows success and renders in list", async ({ page }) => {
      const credential = await createAiCredential(page, { provider: "Custom" })

      const row =
        page
          .locator('button[phx-click="edit_ai_credential"]')
          .filter({ hasText: credential.name })
          .first()

      await expect(row).toBeVisible()
      await expect(row).toContainText("Non-sovereign")
    })

    test("api key is masked by default; show/hide toggles the mask", async ({ page }) => {
      await page.locator('[phx-click="new_ai_credential"]').click()
      await expect(page.locator(SEL.aiCredentialForm)).toBeVisible()

      const input = page.locator("#ai-credential-api-key-input")
      const showBtn = page.locator("#ai-credential-api-key-show")
      const hideBtn = page.locator("#ai-credential-api-key-hide")

      await expect(input).toHaveAttribute("style", /-webkit-text-security: disc/)
      await expect(hideBtn).toHaveClass(/hidden/)

      await showBtn.click()
      await expect(input).not.toHaveAttribute("style", /-webkit-text-security/)
      await expect(showBtn).toHaveClass(/hidden/)
      await expect(hideBtn).not.toHaveClass(/hidden/)

      await hideBtn.click()
      await expect(input).toHaveAttribute("style", /-webkit-text-security: disc/)
      await expect(hideBtn).toHaveClass(/hidden/)
      await expect(showBtn).not.toHaveClass(/hidden/)
    })

    test("new credential can be selected in LLM form and saved", async ({ page }) => {
      const credential = await createAiCredential(page, { provider: "Custom" })

      await page.locator(SEL.tabLLM).click()
      await expect(page.locator(SEL.llmForm)).toBeVisible()

      await pickSearchableSelect(page, "#llm-credential-select", credential.name)
      await page.locator('input[name="llm_config[top_p]"]').fill("0.91")
      await page.getByRole("button", { name: "Save LLM Settings" }).click()
      await expect(page.getByText("LLM settings saved.")).toBeVisible()
    })
  })
})
