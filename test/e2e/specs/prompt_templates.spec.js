const { test, expect } = require("@playwright/test");
const {
  loginToBackOffice,
  openPromptTemplate,
  publishE2EPromptTemplateDefaults,
  seedE2EPromptTemplateDefaults,
  waitForLiveViewSettled,
} = require("../support/bo");

test.describe("Prompt template defaults", () => {
  let templates;

  test.beforeEach(async ({ page, request }) => {
    templates = await seedE2EPromptTemplateDefaults(request);
    await loginToBackOffice(page, { returnTo: "/bo/prompt-templates" });
  });

  test("edited bodies persist across upgrades; restore uses latest default and opts back in", async ({
    page,
    request,
  }) => {
    const slug = "e2e_default_following";
    const id = templates[slug];
    let body = await openPromptTemplate(page, slug);
    await expect(body).toHaveValue("Release default v1");
    await body.fill("My edited image extraction instructions");
    await page.locator(`#save-template-${id}`).click();
    await waitForLiveViewSettled(page);

    await publishE2EPromptTemplateDefaults(request, "Release default v2");
    body = await openPromptTemplate(page, slug);
    await expect(body).toHaveValue("My edited image extraction instructions");

    await page.locator('input[name="prompt_template[name]"]').fill("Unsaved metadata");
    await body.fill("Unsaved body that should be discarded");
    await waitForLiveViewSettled(page);
    await page.locator(`#restore-template-${id}`).click();
    await waitForLiveViewSettled(page);
    await expect(body).toHaveValue("Release default v2");
    await expect(page.locator('input[name="prompt_template[name]"]')).toHaveValue("Unsaved metadata");

    body = await openPromptTemplate(page, slug);
    await expect(body).toHaveValue("Release default v2");
    await expect(page.locator('input[name="prompt_template[name]"]')).toHaveValue(slug);

    await publishE2EPromptTemplateDefaults(request, "Release default v3");
    body = await openPromptTemplate(page, slug);
    await expect(body).toHaveValue("Release default v3");
  });

  test("metadata edits preserve automatic updates while existing customization is retained", async ({
    page,
    request,
  }) => {
    const slug = "e2e_default_following";
    await openPromptTemplate(page, slug);
    await page.locator('input[name="prompt_template[name]"]').fill("Renamed only");
    await page.locator(`#save-template-${templates[slug]}`).click();
    await waitForLiveViewSettled(page);
    await publishE2EPromptTemplateDefaults(request, "Release default v2");

    const following = await openPromptTemplate(page, slug);
    await expect(following).toHaveValue("Release default v2");
    await expect(page.locator('input[name="prompt_template[name]"]')).toHaveValue("Renamed only");

    const customized = await openPromptTemplate(page, "e2e_default_customized");
    await expect(customized).toHaveValue("User-owned body");
    await page.locator(`#restore-template-${templates.e2e_default_customized}`).click();
    await waitForLiveViewSettled(page);
    await expect(customized).toHaveValue("Release default v2");
  });

  test("legacy custom templates without a baseline cannot restore", async ({ page }) => {
    const body = await openPromptTemplate(page, "e2e_default_legacy");
    await expect(body).toHaveValue("Legacy custom body");
    await expect(page.locator(`#restore-template-${templates.e2e_default_legacy}`)).toBeDisabled();
    await expect(page.getByText("No original default is available for this template.")).toBeVisible();
  });
});
