const { test, expect } = require("@playwright/test")
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
  warningHeading: '[data-testid="embedding-warning-title"]',
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
  uploadDataButton: "#upload-data-button",
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

// File row in the ingestion table — match preview button title (stable across browsers).
function fileRow(page, filename) {
  return page
    .locator("#ingestion-file-list tr")
    .filter({ has: page.locator(`button[title="${filename}"]`) })
    .first()
}

async function closeJobsDrawer(page) {
  const drawer = page.locator("#ingestion-jobs-drawer")
  if (await drawer.isVisible().catch(() => false)) {
    await drawer.getByRole("button", { name: /close drawer/i }).click()
    await expect(drawer).not.toBeVisible({ timeout: 5_000 })
    await waitForLiveViewSettled(page)
  }
}

async function ensureAsyncMode(page) {
  await page.locator("#ingest-mode-async").click()
  await waitForLiveViewSettled(page)
  await expect(page.locator("#ingest-mode-async")).toHaveClass(/zaq-btn-tertiary--active/)
}

// Async enqueue: flash confirms dispatch; the jobs drawer auto-opens on success.
// Do not assert "(N active)" on the monitor button — jobs can finish before the
// next LiveView patch in CI, leaving the counter at zero while ingest still succeeded.
async function expectAsyncIngestionStarted(page, filename) {
  const toast = page.locator("#ingest-toast")
  await expect(toast).toBeVisible({ timeout: 15_000 })
  await expect(toast).toContainText("Ingestion started.")
  const drawer = page.locator("#ingestion-jobs-drawer")
  await expect(drawer).toBeVisible({ timeout: 15_000 })
  await expect(
    drawer.locator(".zaq-card-default").filter({ hasText: filename }).first()
  ).toBeVisible({ timeout: 15_000 })
}

// Async completion: wait for terminal job status in the drawer, then the row badge.
async function waitForAsyncRowBadge(page, filename, badge) {
  const terminalStatus = badge === "failed" ? "failed" : "completed"
  const drawer = page.locator("#ingestion-jobs-drawer")

  if (!(await drawer.isVisible().catch(() => false))) {
    await page.locator("#monitor-jobs-button").click()
    await expect(drawer).toBeVisible({ timeout: 10_000 })
  }

  const jobCard = drawer.locator(".zaq-card-default").filter({ hasText: filename }).first()
  await expect(jobCard.getByText(terminalStatus, { exact: true })).toBeVisible({
    timeout: 60_000,
  })

  await closeJobsDrawer(page)
  await waitForLiveViewSettled(page)

  const row = fileRow(page, filename)
  if (badge === "failed") {
    await expect(row.locator("span", { hasText: "failed" })).toBeVisible({ timeout: 15_000 })
    await expect(row.locator("span", { hasText: "ingested" })).not.toBeVisible()
  } else {
    await expect(row.locator("span", { hasText: "ingested" })).toBeVisible({ timeout: 15_000 })
  }
}

// Ensure the file is selected then ingest.
// Uses check() (idempotent) instead of a point-in-time isChecked() read so that
// an in-flight PubSub handle_info re-render cannot produce a stale DOM snapshot
// that causes the selection to be toggled off.
async function selectAndIngest(page, row, filename) {
  // Clear any stale flash FIRST so the "Ingestion started." check below cannot
  // match a leftover toast from a previous call and silently skip the real wait.
  await dismissFlash(page)
  await closeJobsDrawer(page)
  await waitForLiveViewSettled(page)
  const checkbox = row.getByRole("checkbox")
  const ingestButton = page.locator(SEL.ingestButton)
  await expect(checkbox).toBeVisible()
  await checkbox.check()
  await expect(checkbox).toBeChecked()
  await waitForLiveViewSettled(page)
  // The checkbox reflects the browser state immediately, but the server-side
  // @selected set drives whether ingest_selected actually enqueues a job.
  // Wait for LiveView to re-enable the action before clicking, otherwise the
  // click can race ahead of toggle_select and enqueue nothing.
  await expect(ingestButton).toBeEnabled()
  await ingestButton.click()
  await expectAsyncIngestionStarted(page, filename)
  // Dismiss the "Ingestion started." toast so a later call does not match on it.
  await dismissFlash(page)
}

async function openUploadModal(page) {
  await page.locator(SEL.uploadDataButton).click()
  await expect(page.locator("#upload-modal")).toBeVisible()
}

// ── Tests ────────────────────────────────────────────────────────────────────

test.describe("Ingestion", () => {
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
    test.setTimeout(240_000)
    // Use a timestamp-unique filename so parallel/repeated runs don't collide.
    const pdfFilename = `e2e-ingestion-${Date.now()}.pdf`
    // ── Step 1: Reset already seeded embedding config — no warning ────────────
    //
    // POST /e2e/reset re-seeds the default embedding config and ensures the
    // chunks table exists. Assert that configured state directly instead of
    // clicking a no-op save and depending on a success toast.

    await gotoBackOfficeLive(page, INGESTION_PATH)
    await waitForLiveViewSettled(page)
    await ensureAsyncMode(page)

    await expect(
      page.locator(SEL.warningHeading, { hasText: "Embedding not configured" })
    ).not.toBeVisible()

    // ── Step 2: Upload the PDF ────────────────────────────────────────────────

    const tempPdfPath = path.join(os.tmpdir(), pdfFilename)
    fs.writeFileSync(tempPdfPath, minimalPdfBuffer())

    const fileChooserPromise = page.waitForEvent("filechooser")
    await openUploadModal(page)
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fileChooser = await fileChooserPromise
    await fileChooser.setFiles(tempPdfPath)

    // LiveView shows "Upload N file(s)" button once the file is queued.
    const uploadBtn = page.locator(SEL.uploadSubmitButton)
    await expect(uploadBtn).toBeVisible()
    await uploadBtn.click()

    // Flash confirms server processed the upload. Dismiss it so subsequent
    // upload checks cannot match this stale toast.
    await expect(page.getByText(/file\(s\) uploaded\./)).toBeVisible()
    await dismissFlash(page)

    // ── Step 3: Select file and ingest ───────────────────────────────────────
    //
    // Rows are located via ARIA role "row" with the filename as a name substring —
    // this avoids CSS attribute selector issues with multi-hyphen phx-* attributes.

    const row = fileRow(page, pdfFilename)
    await expect(row).toBeVisible()

    await selectAndIngest(page, row, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "ingested")

    // ── Step 3c: Fail a re-ingest while "ingested" is still in the DB ─────────
    //
    // This is the key regression case: documents.content is non-NULL (prior
    // success), so ingested_at != nil. A subsequent failed job must override
    // the "ingested" badge and show "failed" instead.
    // (Previously the cond checked ingested_at before job_status == "failed".)

    await page.request.get("/e2e/processor/fail?count=1")
    await selectAndIngest(page, row, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "failed")

    // Restore the "ingested" state before the model-change step.
    await selectAndIngest(page, row, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "ingested")

    // ── Step 4: Change embedding model → destructive save ────────────────────
    //
    // Changing the model name causes save_embedding_config to call reset_table,
    // which drops + recreates the chunks table AND sets documents.content = NULL.
    // With content = NULL, ingested_at becomes nil in the ingestion_map,
    // making the "ingested" tag disappear.

    await gotoBackOfficeLive(page, `${CONFIG_PATH}?tab=embedding`)
    // Wait for settled BEFORE asserting visibility — `waitForLiveViewConnected` only
    // guarantees the socket is up, not that handle_params (tab switch) has been applied.
    // Without settled first, the embedding form can be briefly visible from a partial
    // render, and the click below races a second diff that morphs the button away.
    await waitForLiveViewSettled(page)
    await expect(page.locator(SEL.embeddingForm)).toBeVisible()

    // Unlock model selection.
    const unlockTrigger = page.locator(SEL.unlockTrigger).first()
    await expect(unlockTrigger).toBeVisible()
    const unlockHeading = page.getByRole("heading", { name: "Unlock Model Selection" })
    // Retry the click: a DOM morph in flight can silently drop the phx-click event.
    await expect(async () => {
      await waitForLiveViewSettled(page)
      await unlockTrigger.click()
      await expect(unlockHeading).toBeVisible({ timeout: 2_000 })
    }).toPass({ intervals: [500, 1_000, 2_000], timeout: 15_000 })
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
    await waitForLiveViewSettled(page)
    await ensureAsyncMode(page)

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

    await selectAndIngest(page, rowAfterReset, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "failed")

    // ── Step 7: Re-ingest (no failure) → "ingested" tag must return ──────────

    await selectAndIngest(page, rowAfterReset, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "ingested")
  })

  // ── Folder rename preserves ingested documents (issue #331) ──────────────
  //
  // When a folder is renamed, the Document records inside it must have their
  // `source` path updated so the files remain findable (with their "ingested"
  // tag intact) after navigating into the renamed folder.

  test("renaming a folder keeps ingested file visible with ingested tag", async ({ page }) => {
    test.setTimeout(120_000)
    const ts = Date.now()
    const folderName = `zaq-rename-${ts}`
    const renamedFolder = `product-rename-${ts}`
    const pdfFilename = `e2e-in-folder-${ts}.pdf`
    await gotoBackOfficeLive(page, INGESTION_PATH)
    await waitForLiveViewSettled(page)
    await ensureAsyncMode(page)

    // ── Create folder via UI ───────────────────────────────────────────────
    await page.locator("#new-folder-button").click()
    await expect(page.locator("#new-folder-input")).toBeVisible()
    await page.locator("#new-folder-input").fill(folderName)
    await page.locator("#new-folder-form").getByRole("button", { name: /create/i }).click()
    await waitForLiveViewSettled(page)

    // ── Navigate into the new folder ──────────────────────────────────────
    await page.getByRole("button", { name: folderName }).click()
    await waitForLiveViewSettled(page)

    // ── Upload a PDF into the folder ──────────────────────────────────────
    const tempPdfPath = path.join(os.tmpdir(), pdfFilename)
    fs.writeFileSync(tempPdfPath, minimalPdfBuffer())

    const fileChooserPromise = page.waitForEvent("filechooser")
    await openUploadModal(page)
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fileChooser = await fileChooserPromise
    await fileChooser.setFiles(tempPdfPath)

    await page.locator(SEL.uploadSubmitButton).click()
    await dismissFlash(page)

    // ── Ingest the uploaded PDF ───────────────────────────────────────────
    const row = fileRow(page, pdfFilename)
    await expect(row).toBeVisible({ timeout: 10_000 })
    await selectAndIngest(page, row, pdfFilename)
    await waitForAsyncRowBadge(page, pdfFilename, "ingested")

    // ── Navigate back to root ─────────────────────────────────────────────
    await page.getByRole("button", { name: "root" }).click()
    await waitForLiveViewSettled(page)

    // ── Rename the folder ─────────────────────────────────────────────────
    const folderRow = fileRow(page, folderName)
    await expect(folderRow).toBeVisible()
    await folderRow.locator('button[phx-click="rename_item"]').click()

    const renameInput = page.locator('input[name="name"]')
    await expect(renameInput).toBeVisible()
    await renameInput.fill(renamedFolder)
    await page.locator("form[phx-submit='confirm_rename']").getByRole("button", { name: /rename/i }).click()
    await waitForLiveViewSettled(page)

    // ── Navigate into the renamed folder ──────────────────────────────────
    await page.getByRole("button", { name: renamedFolder }).click()
    await waitForLiveViewSettled(page)

    // The PDF must still show the "ingested" tag, proving Document.source was
    // updated when the folder was renamed.
    await expect(fileRow(page, pdfFilename)).toBeVisible()
    await expect(fileRow(page, pdfFilename).locator("span", { hasText: "ingested" })).toBeVisible()

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
    await openUploadModal(page)
    await page.locator(SEL.uploadBrowseTrigger).click()
    const fc1 = await chooser1
    await fc1.setFiles(tempPdfPath)
    await page.locator(SEL.uploadSubmitButton).click()
    await expect(page.getByText(/file\(s\) uploaded\./)).toBeVisible()
    // Dismiss so the second upload's flash check cannot match this stale toast.
    await dismissFlash(page)
    await expect(fileRow(page, pdfFilename)).toBeVisible()

    // ── Second upload of the same file ───────────────────────────────────────

    const chooser2 = page.waitForEvent("filechooser")
    await openUploadModal(page)
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
