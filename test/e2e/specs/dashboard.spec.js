const { test, expect } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  createE2EAddonPackage,
} = require("../support/bo");

test.describe("BO Dashboard", () => {
  test.beforeAll(async ({ playwright }) => {
    const req = await playwright.request.newContext();
    await resetE2EState(req);
    await req.dispose();
  });

  test("KPI metric links, cards, and sub-metric CTAs", async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    await expect(page.locator("#dashboard-metric-documents-ingested")).toHaveAttribute(
      "href",
      "/bo/ingestion"
    );
    await expect(page.locator("#dashboard-metric-documents-ingested")).toContainText(
      "Documents ingested"
    );
    await expect(page.locator("#dashboard-metric-documents-ingested-card")).toBeVisible();
    await expect(page.locator("#dashboard-metric-documents-ingested")).toContainText("range: 30d");

    await expect(page.locator("#dashboard-metric-llm-api-calls")).toHaveAttribute(
      "href",
      "/bo/ai-diagnostics"
    );
    await expect(page.locator("#dashboard-metric-llm-api-calls")).toContainText("LLM API calls");

    await expect(page.locator("#dashboard-metric-qa-response-time")).toHaveAttribute(
      "href",
      "/bo/chat"
    );
    await expect(page.locator("#dashboard-metric-qa-response-time-card")).toBeVisible();

    await expect(page.locator("#dashboard-knowledge-base-metrics-link")).toHaveAttribute(
      "href",
      "/bo/dashboard/knowledge-base-metrics"
    );
    await expect(page.locator("#dashboard-llm-performance-link")).toHaveAttribute(
      "href",
      "/bo/dashboard/llm-performance"
    );
    await expect(page.locator("#dashboard-conversations-metrics-link")).toHaveAttribute(
      "href",
      "/bo/dashboard/conversations-metrics"
    );
  });

  test("services table lists core services with a status pill", async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    await expect(page.getByText("Services", { exact: true })).toBeVisible();

    const names = ["Engine", "Agent", "Ingestion", "Channels", "Back Office"];
    for (const name of names) {
      await expect(page.locator("tbody tr").filter({ hasText: name })).toHaveCount(1);
    }

    const rows = page.locator("tbody tr");
    await expect(rows).toHaveCount(5);

    const statusCells = page.locator("tbody tr td:last-child");
    const statuses = await statusCells.allTextContents();
    expect(statuses.every((t) => /Running|Disabled/.test(t.trim()))).toBeTruthy();

    await expect(page.locator("tbody tr").filter({ hasText: "Back Office" })).toContainText(
      "Running"
    );
  });

  test("add-ons empty state", async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    await expect(page.getByText("Add-ons", { exact: true })).toBeVisible();
    await expect(page.getByText("No Add-ons")).toBeVisible();
    await expect(page.getByText("Running in basic mode")).toBeVisible();
    const emptyCta = page.getByTestId("addon-upsell-cta");
    await expect(emptyCta).toBeVisible();
    await expect(emptyCta).toHaveText("View Add-ons");
    await expect(emptyCta).toHaveAttribute("href", "/bo/addons");
  });

  test("add-ons loaded state", async ({ page, request }) => {
    await resetE2EState(request);

    const future = new Date(Date.now() + 45 * 86_400_000).toISOString();
    await createE2EAddonPackage(request, {
      company_name: "E2E Addon Co",
      license_key: "lic-e2e-dashboard",
      expires_at: future,
      features: [{ name: "ontology" }, { name: "reports" }],
    });

    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    await expect(page.getByText("E2E Addon Co")).toBeVisible();
    await expect(page.getByText("lic-e2e-dashboard")).toBeVisible();

    const loadedCta = page.getByTestId("addon-summary-cta");
    await expect(loadedCta).toBeVisible();
    await expect(loadedCta).toHaveText("View Add-ons");
    await expect(loadedCta).toHaveAttribute("href", "/bo/addons");
  });
});
