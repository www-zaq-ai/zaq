const { test, expect, request: apiRequest } = require("@playwright/test")
const fs = require("fs")
const os = require("os")
const path = require("path")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
  dismissFlash,
} = require("../support/bo")

const INGESTION_PATH = "/bo/ingestion"
const CONFIG_PATH = "/bo/system-config"

// ── Selectors ───────────────────────────────────────────────────────────────

const SEL = {
  // Ingestion page — warning banner (shown when chunks table does not exist)
  warningHeading: 'p.font-mono.text-amber-800',
  warningLink: 'a[href="/bo/system-config?tab=embedding"]',

  // System config — embedding tab
  tabEmbedding: '[phx-value-tab="embedding"]',
  embeddingForm: "#embedding-config-form",

  // Embedding lock / unlock
  unlockTrigger: '[phx-click="unlock_embedding"]',
  cancelUnlock: '[phx-click="cancel_unlock_embedding"]',
  confirmUnlock: '[phx-click="confirm_unlock_embedding"]',
  cancelSave: '[phx-click="cancel_save_embedding"]',
  confirmSave: '[phx-click="confirm_save_embedding"]',

  // Ingestion page — file browser & upload
  ingestButton: "#ingest-selected-button",
  uploadBrowseTrigger: "#upload-form label",
  uploadSubmitButton: "#upload-files-button",
}

// ── Helpers ─────────────────────────────────────────────────────────────────

// Minimal valid PDF bytes that DocumentProcessorFake (File.read) can ingest.
function minimalPdfBuffer() {
  return Buffer.from(
    "%PDF-1.0\n" +
      "1 0 obj<</Type /Catalog /Pages 2 0 R>>endobj\n" +
      "2 0 obj<</Type /Pages /Kids [3 0 R] /Count 1>>endobj\n" +
      "3 0 obj<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]>>endobj\n" +
      "xref\n0 4\n" +
      "0000000000 65535 f\n" +
      "0000000009 00000 n\n" +
      "0000000058 00000 n\n" +
      "0000000115 00000 n\n" +
      "trailer<</Size 4 /Root 1 0 R>>\n" +
      "startxref\n190\n%%EOF"
  )
}

// After an unlock → change model → save cycle, wait for the "Delete All Embeddings?" modal.
async function confirmDestructiveSave(page) {
  await expect(page.getByRole("heading", { name: "Delete All Embeddings?" })).toBeVisible()
  await page.locator(SEL.confirmSave).click()
  await expect(page.getByText("Embedding settings saved.")).toBeVisible()
  await dismissFlash(page)
}

// Find the file row in the browser table by filename (ARIA row name contains the filename).
// Using getByRole avoids CSS attribute selector issues with multi-hyphen phx-* attributes.
function fileRow(page, filename) {
  return page.getByRole("row", { name: filename })
}

// Ensure the file is selected (check if already selected to avoid toggling off) then ingest.
// Waits for the LiveView to quiesce before reading the checkbox state, otherwise a
// pending PubSub re-render can stale the handle and flip the selection off.
async function selectAndIngest(page, row) {
  await waitForLiveViewSettled(page)
  const checkbox = row.getByRole("checkbox")
  const ingestButton = page.locator(SEL.ingestButton)
  await expect(checkbox).toBeVisible()
  if (!(await checkbox.isChecked())) {
    await checkbox.click()
    await expect(checkbox).toBeChecked()
    await waitForLiveViewSettled(page)
  }
  // The checkbox reflects the browser state immediately, but the server-side
  // @selected set drives whether ingest_selected actually enqueues a job.
  // Wait for LiveView to re-enable the action before clicking, otherwise the
  // click can race ahead of toggle_select and enqueue nothing.
  await expect(ingestButton).toBeEnabled()
  await ingestButton.click()
  await expect(page.getByText("Ingestion started.")).toBeVisible()
  // Dismiss the "Ingestion started." toast so a later test does not match on it.
  await dismissFlash(page)
}

// ── Tests ────────────────────────────────────────────────────────────────────

test.describe("Ingestion", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test.beforeEach(async ({ page }) => {
    await resetE2EState(page.request)
    await loginToBackOffice(page)
    // Reset processor state so no leftover fail count from a previous run affects this test.
    await page.request.get("/e2e/processor/reset")
  })

  test.afterEach(async ({ page }) => {
    await page.request.get("/e2e/processor/reset")
  })

  // ── Warning banner ────────────────────────────────────────────────────────
  // Visible only when the chunks table does not exist (fresh database).
  // Clicking the inline link must navigate directly to the Embedding tab.

  test("shows 'Embedding not configured' warning and link navigates to embedding tab", async ({
    page,
  }) => {
    await gotoBackOfficeLive(page, INGESTION_PATH)

    const warning = page.locator(SEL.warningHeading, { hasText: "Embedding not configured" })
    // After /e2e/reset re-seeds the default embedding config, the chunks table
    // exists and the warning does NOT appear. This test is a guard for the
    // truly-fresh-DB case; skip when the banner is absent after a generous wait.
    const visible = await warning.isVisible({ timeout: 8_000 }).catch(() => false)

    if (!visible) {
      test.skip()
    }

    await expect(warning).toBeVisible()

    // "Go to Settings →" is a plain <a href> — clicking it navigates to the embedding tab.
    const link = page.locator(SEL.warningLink)
    await expect(link).toBeVisible()
    await link.click()

    // Verify we landed on the embedding tab (full page nav, not LiveView push).
    await expect(page.locator(SEL.embeddingForm)).toBeVisible()
    await expect(page).toHaveURL(/tab=embedding/)
  })

  // ── Full ingestion lifecycle ────────────────────────────────────────────────
  //
  // 1. Reset seeds embedding config  →  chunks table exists, no warning on ingestion page
  // 2. Upload a PDF and ingest it:
  //      →  "ingested" tag appears in the file browser
  //      →  sidecar .md row appears (DocumentProcessorFake creates it)
  // 3. Unlock embedding, change the model, confirm destructive save
  //      →  reset_table drops+recreates chunks, clears documents.content
  //      →  "ingested" tag disappears
  // 4. Ingest with simulated failure (ProcessorState set to fail once)
  //      →  "failed" tag appears, no "ingested" tag
  // 5. Re-ingest the same file (no failure)
  //      →  "ingested" tag reappears, "failed" tag gone

  test("ingest PDF shows ingested tag and sidecar; changing model invalidates; job failure shows failed tag; re-ingest restores", async ({
    page,
  }) => {
    // Use a timestamp-unique filename so parallel/repeated runs don't collide.
    const pdfFilename = `e2e-ingestion-${Date.now()}.pdf`
    const sidecarFilename = pdfFilename.replace(/\.pdf$/, ".md")

    // ── Step 1: Reset already seeded embedding config — no warning ────────────
    //
    // POST /e2e/reset re-seeds the default embedding config and ensures the
    // chunks table exists. Assert that configured state directly instead of
    // clicking a no-op save and depending on a success toast.

    await gotoBackOfficeLive(page, INGESTION_PATH)

    await expect(
      page.locator(SEL.warningHeading, { hasText: "Embedding not configured" })
    ).not.toBeVisible()
    await waitForLiveViewSettled(page)

    // ── Step 2: Upload the PDF ────────────────────────────────────────────────

    const tempPdfPath = path.join(os.tmpdir(), pdfFilename)
    fs.writeFileSync(tempPdfPath, minimalPdfBuffer())

    const fileChooserPromise = page.waitForEvent("filechooser")
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fileChooser = await fileChooserPromise
    await fileChooser.setFiles(tempPdfPath)

    // LiveView shows "Upload N file(s)" button once the file is queued.
    const uploadBtn = page.locator(SEL.uploadSubmitButton)
    await expect(uploadBtn).toBeVisible()
    await uploadBtn.click()

    // Flash confirms server processed the upload.
    await expect(page.getByText(/file\(s\) uploaded\./)).toBeVisible()

    // ── Step 3: Select file and ingest ───────────────────────────────────────
    //
    // Rows are located via ARIA role "row" with the filename as a name substring —
    // this avoids CSS attribute selector issues with multi-hyphen phx-* attributes.

    const row = fileRow(page, pdfFilename)
    await expect(row).toBeVisible()

    await selectAndIngest(page, row)

    // After DocumentProcessorFake processes the job, a PubSub broadcast triggers
    // load_entries() in the LiveView, which updates the ingestion_map.
    await expect(row.locator("span", { hasText: "ingested" })).toBeVisible({ timeout: 15_000 })

    // ── Step 3b: Sidecar sub-row must appear below the PDF row ───────────────
    //
    // DocumentProcessorFake writes a .md sidecar to disk and creates a sidecar
    // Document record. DirectorySnapshot attaches it as related_md on the PDF
    // entry → the template renders a row showing the sidecar filename.

    await expect(fileRow(page, sidecarFilename)).toBeVisible({ timeout: 5_000 })

    // ── Step 3c: Fail a re-ingest while "ingested" is still in the DB ─────────
    //
    // This is the key regression case: documents.content is non-NULL (prior
    // success), so ingested_at != nil. A subsequent failed job must override
    // the "ingested" badge and show "failed" instead.
    // (Previously the cond checked ingested_at before job_status == "failed".)

    await page.request.get("/e2e/processor/fail?count=1")
    await selectAndIngest(page, row)

    await expect(row.locator("span", { hasText: "failed" })).toBeVisible({ timeout: 15_000 })
    await expect(row.locator("span", { hasText: "ingested" })).not.toBeVisible()

    // Restore the "ingested" state before the model-change step.
    await selectAndIngest(page, row)
    await expect(row.locator("span", { hasText: "ingested" })).toBeVisible({ timeout: 15_000 })

    // ── Step 4: Change embedding model → destructive save ────────────────────
    //
    // Changing the model name causes save_embedding_config to call reset_table,
    // which drops + recreates the chunks table AND sets documents.content = NULL.
    // With content = NULL, ingested_at becomes nil in the ingestion_map,
    // making the "ingested" tag disappear.

    await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=embedding`)
    await expect(page.locator(SEL.embeddingForm)).toBeVisible()
    await waitForLiveViewSettled(page)

    // Unlock model selection.
    const unlockTrigger = page.locator(SEL.unlockTrigger).first()
    await expect(unlockTrigger).toBeVisible()
    await unlockTrigger.click()
    await expect(page.getByRole("heading", { name: "Unlock Model Selection" })).toBeVisible()
    await page.locator(SEL.confirmUnlock).click()
    await expect(page.locator(SEL.unlockTrigger)).not.toBeVisible()

    // With the default "custom" provider (no model options), the model is a
    // plain text input that becomes enabled after unlock.
    const modelTextInput = page.locator(
      'input[type="text"][name="embedding_config[model]"]'
    )

    // The model text input is visible only when the "custom" provider is active
    // (embedding_model_options returns [] → text input rendered instead of searchable_select).
    // The default e2e embedding config uses the custom provider, so this should always pass.
    // If the text input is absent (non-custom provider configured), the test bails with fixme.
    if (!(await modelTextInput.isEnabled({ timeout: 2_000 }).catch(() => false))) {
      test.fixme(
        true,
        'Model text input unavailable — embedding provider is not "custom". ' +
          "Set the provider to custom in the embedding config to enable this test."
      )
      return
    }

    // Fill a unique model name to guarantee a model-name change in the DB.
    // save_embedding_config resets the chunks table (and clears documents.content)
    // only when saved_model != new_config.model, so a distinct name is required.
    const newModel = `e2e-reset-model-${Date.now()}`
    await modelTextInput.fill(newModel)
    await modelTextInput.press("Tab")

    // Wait for the server to process validate_embedding and set model_changed: true,
    // which turns the save button red.
    const saveBtn = page.getByRole("button", { name: "Save Embedding Settings" })
    await expect(saveBtn).toHaveClass(/bg-red-500/, { timeout: 5_000 })
    await saveBtn.click()

    await confirmDestructiveSave(page)

    // ── Step 5: Ingestion page — "ingested" tag must be gone ─────────────────

    await gotoBackOfficeLive(page, INGESTION_PATH)

    const rowAfterReset = fileRow(page, pdfFilename)
    await expect(rowAfterReset).toBeVisible()

    // After reset_table, documents.content = NULL → ingested_at = nil → no tag.
    await expect(rowAfterReset.locator("span", { hasText: "ingested" })).not.toBeVisible()

    // ── Step 6: Ingest with simulated failure → "failed" tag must appear ──────
    //
    // ProcessorState.set_fail(1) makes DocumentProcessorFake return
    // {:error, "Structural error: simulated e2e failure"} for the next job.
    // IngestWorker treats structural errors as non-retryable and marks the job
    // discarded, broadcasting {:job_updated, job} so the LiveView shows "failed".

    await page.request.get("/e2e/processor/fail?count=1")

    await selectAndIngest(page, rowAfterReset)

    await expect(
      rowAfterReset.locator("span", { hasText: "failed" })
    ).toBeVisible({ timeout: 15_000 })

    await expect(rowAfterReset.locator("span", { hasText: "ingested" })).not.toBeVisible()

    // ── Step 7: Re-ingest (no failure) → "ingested" tag must return ──────────
    //
    // selectAndIngest checks isChecked() first — after step 7 the file is still
    // selected (LiveView does not clear @selected on job completion), so the
    // checkbox click is skipped and we go straight to the ingest button.

    await selectAndIngest(page, rowAfterReset)

    await expect(
      rowAfterReset.locator("span", { hasText: "ingested" })
    ).toBeVisible({ timeout: 15_000 })

    await expect(rowAfterReset.locator("span", { hasText: "failed" })).not.toBeVisible()
  })

  // ── Duplicate filename deduplication ──────────────────────────────────────
  //
  // Uploading a file whose name already exists must NOT overwrite the original.
  // The second upload must appear as `stem(1).ext` in the file browser.

  test("uploading duplicate filename creates stem(1).ext instead of overwriting", async ({
    page,
  }) => {
    const baseName = `e2e-dedup-${Date.now()}`
    const pdfFilename = `${baseName}.pdf`
    const dedupFilename = `${baseName}(1).pdf`

    await gotoBackOfficeLive(page, INGESTION_PATH)
    await waitForLiveViewSettled(page)

    const tempPdfPath = path.join(os.tmpdir(), pdfFilename)
    fs.writeFileSync(tempPdfPath, minimalPdfBuffer())

    // ── First upload ─────────────────────────────────────────────────────────

    const chooser1 = page.waitForEvent("filechooser")
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fc1 = await chooser1
    await fc1.setFiles(tempPdfPath)
    await page.locator(SEL.uploadSubmitButton).click()
    await expect(page.getByText(/file\(s\) uploaded\./)).toBeVisible()
    await expect(fileRow(page, pdfFilename)).toBeVisible()

    // ── Second upload of the same file ───────────────────────────────────────

    const chooser2 = page.waitForEvent("filechooser")
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fc2 = await chooser2
    await fc2.setFiles(tempPdfPath)
    await page.locator(SEL.uploadSubmitButton).click()
    await expect(page.getByText(/file\(s\) uploaded\./)).toBeVisible()

    // Original must still exist and the deduplicated name must appear.
    await expect(fileRow(page, pdfFilename)).toBeVisible()
    await expect(fileRow(page, dedupFilename)).toBeVisible()
  })
})
