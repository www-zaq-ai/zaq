const { test, expect, request: apiRequest } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  touchE2EFile,
  dismissFlash,
  waitForLiveViewSettled,
} = require("../support/bo");

const PROMPT_VARIANT_MARKER = "E2E_PROMPT_VARIANT_B";

function uniqueId(prefix) {
  return `${prefix}-${Date.now()}`;
}

function previewPath(relativePath) {
  const encoded = relativePath
    .split("/")
    .filter(Boolean)
    .map((segment) => encodeURIComponent(segment))
    .join("/");

  return `/bo/preview/${encoded}`;
}

async function addRawMarkdown(page, fileNameWithoutExt, content) {
  await page.locator("#add-raw-md-button").click();
  await expect(page.locator("#add-raw-modal")).toBeVisible();

  await page.locator("#raw-filename-input").fill(fileNameWithoutExt);
  await page.locator("#raw-content-input").fill(content);
  await page.locator("#save-raw-file-button").click();

  await expect(page.locator("#add-raw-modal")).toBeHidden();
}

async function selectFileRow(page, fileName) {
  const row = fileRow(page, fileName);
  await expect(row).toBeVisible();

  const checkbox = row.locator('input[type="checkbox"]').first();
  await checkbox.check();
  await expect(checkbox).toBeChecked();
}

function fileRow(page, fileName) {
  return page
    .locator("tr")
    .filter({ has: page.locator(`button[phx-click=\"open_preview\"][title=\"${fileName}\"]`) })
    .first();
}

async function ingestSelectedInline(page) {
  await expect(page.locator("#ingest-selected-button")).toContainText("(1)");
  await page.locator("#ingest-mode-inline").click();
  await page.locator("#ingest-selected-button").click();
  // Wait for the LiveView to respond — selection resets to (0) only after the server
  // finishes processing ingest_selected (inline ingestion runs synchronously on the server).
  await expect(page.locator("#ingest-selected-button")).toContainText("(0)");
}

async function askQuestion(page, question) {
  await gotoBackOfficeLive(page, "/bo/chat");
  await expect(page.locator("#chat-form")).toBeVisible();
  await page.locator("#clear-chat-button").click();

  // Wait for the clear to settle server-side before typing the next question.
  // Without this, the fill() below can race with a pending phx-click-loading
  // cycle and the message buffer is repopulated with the stale conversation.
  await waitForLiveViewSettled(page);

  await page.locator("#chat-input").fill(question);
  await page.locator("#chat-form button[type='submit']").click();
}

async function openFirstSourcePreviewModal(page) {
  const sourceChip = page.locator('[data-testid="source-chip"]').first();
  await expect(sourceChip).toBeVisible();
  await expect(sourceChip).toBeEnabled();
  await sourceChip.click();

  const modal = page.locator("#file-preview-modal");
  await expect(modal).toBeVisible();
  await expect(page).toHaveURL(/\/bo\/chat/);
  return modal;
}

async function resetAnsweringPromptTemplate(page) {
  await gotoBackOfficeLive(page, "/bo/prompt-templates");
  await page.locator("#prompt-tab-answering").click();

  const bodyField = page.locator("textarea[id^='prompt-template-body-']").first();
  const existingBody = await bodyField.inputValue();

  if (existingBody.includes(PROMPT_VARIANT_MARKER)) {
    await bodyField.fill(existingBody.replace(`\n\n${PROMPT_VARIANT_MARKER}`, "").replace(PROMPT_VARIANT_MARKER, ""));
    await page.locator("button[id^='save-template-']").first().click();
    await waitForLiveViewSettled(page);
  }
}

test.describe("Knowledge Ops Lead journeys", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext();
    await resetE2EState(req);
    await req.dispose();
  });

  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page);
    await resetAnsweringPromptTemplate(page);
  });

  test("Journey 1: ingest new knowledge and confirm it is queryable", async ({ page }) => {
    const fileBase = uniqueId("e2e-journey-one");
    const fileName = `${fileBase}.md`;
    const queryToken = `${fileBase.replace(/-/g, "_")}_signal`;

    await gotoBackOfficeLive(page, "/bo/ingestion");
    await addRawMarkdown(
      page,
      fileBase,
      `# Journey One Source\n\nThis document contains ${queryToken} and should be retrieved first.`
    );

    await selectFileRow(page, fileName);
    await ingestSelectedInline(page);

    await gotoBackOfficeLive(page, "/bo/ingestion");

    await page.goto(previewPath(fileName));
    await expect(page.locator("body")).toContainText(queryToken);

    const [rawPage] = await Promise.all([
      page.waitForEvent("popup"),
      page.getByRole("link", { name: "Raw" }).click(),
    ]);

    await rawPage.waitForLoadState("domcontentloaded");
    await expect(rawPage.locator("body")).toContainText(queryToken);
    await rawPage.close();

    await askQuestion(page, `What do you know about ${queryToken}?`);
    await expect(page.locator("#chat-messages")).toContainText(
      "Baseline response generated from the default prompt template.",
      { timeout: 30_000 }
    );

    const modal = await openFirstSourcePreviewModal(page);
    await expect(modal).toContainText(queryToken);
  });

  test("Journey 2: maintain hierarchy and stale-document hygiene", async ({ page, request }) => {
    const folderName = uniqueId("e2e-folder");
    const fileBase = uniqueId("e2e-hygiene");
    const fileName = `${fileBase}.md`;

    await gotoBackOfficeLive(page, "/bo/ingestion");

    await page.locator("#new-folder-button").click();
    await expect(page.locator("#new-folder-modal")).toBeVisible();
    await page.locator("#new-folder-input").fill(folderName);
    await page.locator("#create-folder-button").click();
    await expect(page.locator("#new-folder-modal")).toBeHidden();

    await page
      .locator('table button[phx-click="navigate"]')
      .filter({ hasText: folderName })
      .first()
      .click();
    await expect(page.locator("main")).toContainText(folderName);

    await addRawMarkdown(page, fileBase, "# Hygiene v1\n\nInitial content for stale check.");
    await selectFileRow(page, fileName);
    await ingestSelectedInline(page);
    // Wait for the PubSub handle_info cycle: job_updated → load_entries → doc.updated_at = T1.
    // Only after this is the document recorded in the DB with its ingested timestamp.
    await expect(fileRow(page, fileName)).toContainText("ingested");

    await gotoBackOfficeLive(page, "/bo/ingestion");
    await page
      .locator('table button[phx-click="navigate"]')
      .filter({ hasText: folderName })
      .first()
      .click();
    // Wait for the navigate event to be processed and the file row to appear.
    await expect(fileRow(page, fileName)).toBeVisible();

    // Overwrite the file first. save_raw_content calls File.write! which stamps
    // mtime = now — this may or may not exceed doc.updated_at depending on
    // filesystem granularity, so we bump mtime explicitly after the write.
    await addRawMarkdown(page, fileBase, "# Hygiene v2\n\nUpdated content should mark file stale.");

    // Now bump mtime to guarantee it's strictly greater than doc.updated_at (T1).
    // Must happen AFTER the write — File.write resets mtime to now and would
    // clobber a pre-write bump.
    await touchE2EFile(request, `${folderName}/${fileName}`);

    // Re-enter the folder so load_entries runs again and picks up the bumped mtime.
    await gotoBackOfficeLive(page, "/bo/ingestion");
    await page
      .locator('table button[phx-click="navigate"]')
      .filter({ hasText: folderName })
      .first()
      .click();
    await expect(fileRow(page, fileName)).toContainText("stale");

    await page.goto(previewPath(`${folderName}/${fileName}`));
    await expect(page.locator("body")).toContainText("Updated content should mark file stale");
  });

  test("Journey 3: tune prompts and verify answer-quality loop", async ({ page }) => {
    const controlQuestion = "What does the employee benefits handbook include?";

    await gotoBackOfficeLive(page, "/bo/prompt-templates");
    await expect(page.locator("#prompt-tab-answering")).toBeVisible();

    await askQuestion(page, controlQuestion);
    await expect(page.locator("#chat-messages")).toContainText(
      "Baseline response generated from the default prompt template.",
      { timeout: 30_000 }
    );

    await gotoBackOfficeLive(page, "/bo/prompt-templates");
    await page.locator("#prompt-tab-answering").click();

    const bodyField = page.locator("textarea[id^='prompt-template-body-']").first();
    const existingBody = await bodyField.inputValue();

    if (!existingBody.includes(PROMPT_VARIANT_MARKER)) {
      await bodyField.fill(`${existingBody}\n\n${PROMPT_VARIANT_MARKER}`);
    }

    await page.locator("button[id^='save-template-']").first().click();

    await askQuestion(page, controlQuestion);
    await expect(page.locator("#chat-messages")).toContainText(
      "Tuned response generated from the updated prompt template.",
      { timeout: 30_000 }
    );

    const modal = await openFirstSourcePreviewModal(page);
    await expect(modal).toContainText("Employee Benefits Handbook");
  });

  test("Journey 4: unsupported source chips are visible but disabled", async ({ page }) => {
    await gotoBackOfficeLive(page, "/bo/history");

    const row = page.locator("tr", { hasText: "E2E Unsupported Source Conversation" }).first();
    await expect(row).toBeVisible();
    await row.getByRole("link", { name: "View →" }).click();

    await expect(page).toHaveURL(/\/bo\/conversations\//);

    const sourceChip = page.locator('[data-testid="source-chip"]').first();
    await expect(sourceChip).toBeVisible();
    await expect(sourceChip).toBeDisabled();
    await expect(sourceChip).toHaveAttribute("title", "Preview unavailable");

    await sourceChip.click({ force: true });
    await expect(page.locator("#file-preview-modal")).toBeHidden();
    await expect(page).toHaveURL(/\/bo\/conversations\//);
  });
});
