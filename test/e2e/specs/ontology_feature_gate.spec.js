const { test, expect } = require("@playwright/test");
const { gotoBackOfficeLive, loginToBackOffice, resetE2EState } = require("../support/bo");

test.describe("Ontology feature gate", () => {
  test.beforeAll(async ({ playwright }) => {
    const req = await playwright.request.newContext();
    await resetE2EState(req);
    await req.dispose();
  });

  test("shows add-on upsell when ontology feature is not loaded", async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/ontology");

    await expect(page.getByText("Feature Not Enabled")).toBeVisible();
    await expect(page.getByText(/ontology feature is not enabled/i)).toBeVisible();

    const cta = page.getByTestId("addon-upsell-cta");
    await expect(cta).toBeVisible();
    await expect(cta).toHaveText("View Add-ons");
    await expect(cta).toHaveAttribute("href", "/bo/addons");
  });
});
