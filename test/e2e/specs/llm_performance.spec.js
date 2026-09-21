const { test, expect } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  seedE2ELLMPerformance,
  waitForLiveViewSettled,
} = require("../support/bo");

test.describe("BO LLM performance", () => {
  test.beforeEach(async ({ request }) => {
    await resetE2EState(request);
    await seedE2ELLMPerformance(request);
  });

  test("refreshes ranges and keeps retrieval effectiveness below global charts", async ({
    page,
  }) => {
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard/llm-performance");

    const apiCalls = page.locator("#llm-performance-api-calls-chart");
    const retrieval = page.locator("#llm-performance-retrieval-effectiveness");
    const rankings = page.locator("#llm-performance-rankings");

    await expect(apiCalls).toBeVisible();
    await expect(retrieval).toBeVisible();
    await expect(rankings).toBeVisible();
    expect(
      await apiCalls.evaluate(
        (node) =>
          (node.compareDocumentPosition(
            document.querySelector("#llm-performance-retrieval-effectiveness")
          ) &
            Node.DOCUMENT_POSITION_FOLLOWING) !==
          0
      )
    ).toBe(true);
    expect(
      await retrieval.evaluate(
        (node) =>
          (node.compareDocumentPosition(document.querySelector("#llm-performance-rankings")) &
            Node.DOCUMENT_POSITION_FOLLOWING) !==
          0
      )
    ).toBe(true);

    await page.locator("#llm-performance-range-24h").click();
    await waitForLiveViewSettled(page);
    await expect(page.locator("#llm-performance-selected-range")).toHaveText("24h");
    await expect(page.locator("#llm-performance-range-24h")).toHaveAttribute("data-active", "true");

    await page.locator("#llm-performance-range-30d").click();
    await waitForLiveViewSettled(page);
    await expect(page.locator("#llm-performance-selected-range")).toHaveText("30d");
  });

  test("sorting changes model and people top-five membership", async ({ page }) => {
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard/llm-performance");

    const models = page.locator("#llm-top-models-table");
    const people = page.locator("#llm-top-people-table");

    await expect(models).toContainText("e2e-alpha");
    await expect(models).not.toContainText("e2e-foxtrot");
    await expect(people).toContainText("Ada Lovelace");
    await expect(people).not.toContainText("Mary Jackson");

    await page.locator("#llm-model-sort-calls").click();
    await page.locator("#llm-people-sort-calls").click();
    await waitForLiveViewSettled(page);

    await expect(models).toContainText("e2e-foxtrot");
    await expect(models).not.toContainText("e2e-alpha");
    await expect(people).toContainText("Mary Jackson");
    await expect(people).not.toContainText("Ada Lovelace");
  });

  test("agent selection filters lower charts without changing global charts", async ({ page }) => {
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard/llm-performance");

    const globalCalls = page.locator("#llm-performance-api-calls-chart");
    const globalTokens = page.locator("#llm-performance-token-usage-chart");
    const callsBefore = await globalCalls.textContent();
    const tokensBefore = await globalTokens.textContent();

    await page.locator("#llm-agent-select [data-select-trigger]").click();
    await page
      .locator('#llm-agent-select [data-select-option="Support Agent"]')
      .click();
    await waitForLiveViewSettled(page);

    await expect(page.locator("#llm-performance-agent-api-calls-chart")).toBeVisible();
    await expect(page.locator("#llm-performance-agent-token-usage-chart")).toBeVisible();
    await expect(globalCalls).toHaveText(callsBefore);
    await expect(globalTokens).toHaveText(tokensBefore);
  });

  test("renders safe empty states when attributed telemetry is unavailable", async ({
    page,
    request,
  }) => {
    await seedE2ELLMPerformance(request, "clear");
    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard/llm-performance");

    await expect(page.locator("#llm-top-models-table")).toContainText(
      "No attributed usage in this range."
    );
    await expect(page.locator("#llm-top-people-table")).toContainText(
      "No attributed usage in this range."
    );
    await expect(page.locator("#llm-agent-empty")).toContainText(
      "Select an agent to view its usage."
    );
    await expect(page.locator("#llm-performance-api-calls-chart")).toBeVisible();
    await expect(page.locator("#llm-performance-token-usage-chart")).toBeVisible();
  });
});
