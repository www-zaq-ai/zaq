const { test, expect } = require("@playwright/test");
const { gotoBackOfficeLive, loginToBackOffice } = require("../support/bo");

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
  const row = page.locator("tr", { hasText: fileName });
  await expect(row).toBeVisible();

  const checkbox = row.locator('input[type="checkbox"]').first();
  await checkbox.check();
  await expect(checkbox).toBeChecked();
}

async function ingestSelectedInline(page) {
  await expect(page.locator("#ingest-selected-button")).toContainText("(1)");
  await page.locator("#ingest-mode-inline").click();
  await page.locator("#ingest-selected-button").click();
}

async function askQuestion(page, question) {
  await gotoBackOfficeLive(page, "/bo/playground");
  await expect(page.locator("#chat-form")).toBeVisible();
  await page.locator("#clear-chat-button").click();
  await page.locator("#chat-input").fill(question);
  await page.locator("#chat-form button[type='submit']").click();
}

test.describe("Knowledge Ops Lead journeys", () => {
  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page);
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
      "Baseline response generated from the default prompt template."
    );

    const sourceChip = page.locator('[data-testid="source-chip"]').first();
    await expect(sourceChip).toBeVisible();
    await sourceChip.click();

    await expect(page).toHaveURL(new RegExp(`/bo/preview/${fileBase}`));
    await expect(page.locator("body")).toContainText(queryToken);
  });

  test("Journey 2: maintain hierarchy and stale-document hygiene", async ({ page }) => {
    const folderName = uniqueId("e2e-folder");
    const fileBase = uniqueId("e2e-hygiene");
    const fileName = `${fileBase}.md`;

    await gotoBackOfficeLive(page, "/bo/ingestion");

    await page.locator("#new-folder-button").click();
    await expect(page.locator("#new-folder-modal")).toBeVisible();
    await page.locator("#new-folder-input").fill(folderName);
    await page.locator("#create-folder-button").click();
    await expect(page.locator("#new-folder-modal")).toBeHidden();

    await page.getByRole("button", { name: folderName }).first().click();
    await expect(page.locator("main")).toContainText(folderName);

    await addRawMarkdown(page, fileBase, "# Hygiene v1\n\nInitial content for stale check.");
    await selectFileRow(page, fileName);
    await ingestSelectedInline(page);

    await gotoBackOfficeLive(page, "/bo/ingestion");
    await page.getByRole("button", { name: folderName }).first().click();

    await page.waitForTimeout(2500);
    await addRawMarkdown(page, fileBase, "# Hygiene v2\n\nUpdated content should mark file stale.");

    await gotoBackOfficeLive(page, "/bo/ingestion");
    await page.getByRole("button", { name: folderName }).first().click();
    await expect(page.locator("tr", { hasText: fileName })).toContainText("stale");

    await page.goto(previewPath(`${folderName}/${fileName}`));
    await expect(page.locator("body")).toContainText("Updated content should mark file stale");
  });

  test("Journey 3: tune prompts and verify answer-quality loop", async ({ page }) => {
    const controlQuestion = "What does the employee benefits handbook include?";

    await gotoBackOfficeLive(page, "/bo/prompt-templates");
    await expect(page.locator("#prompt-tab-answering")).toBeVisible();

    await askQuestion(page, controlQuestion);
    await expect(page.locator("#chat-messages")).toContainText(
      "Baseline response generated from the default prompt template."
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
      "Tuned response generated from the updated prompt template."
    );

    const sourceChip = page.locator('[data-testid="source-chip"]').first();
    await expect(sourceChip).toBeVisible();
    await sourceChip.click();

    await expect(page).toHaveURL(/\/bo\/preview\//);
    await expect(page.locator("body")).toContainText("Employee Benefits Handbook");
  });
});
