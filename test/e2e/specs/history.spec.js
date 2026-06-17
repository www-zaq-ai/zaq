const { test, expect } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
  createE2EConversation,
} = require("../support/bo");

const HISTORY_PATH = "/bo/history";

test.describe("BO History page", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
  });

  test("renders tabs, filters, admin scope, and table shell", async ({ page }) => {
    await gotoBackOfficeLive(page, HISTORY_PATH);

    await expect(page.getByRole("link", { name: "Active" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Archived" })).toBeVisible();
    await expect(page.locator("#channel_type")).toBeVisible();

    await expect(page.getByRole("columnheader", { name: "Conversation" })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Channel" })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Started" })).toBeVisible();
    await expect(page.getByRole("columnheader", { name: "Updated" })).toBeVisible();

    await expect(page.getByText(/\d+ conversations/)).toBeVisible();

    await expect(page.getByRole("button", { name: "My History" })).toBeVisible();
    await expect(page.getByRole("button", { name: "All Users" })).toBeVisible();

    await expect(
      page.locator("tr").filter({ hasText: "E2E Unsupported Source Conversation" })
    ).toBeVisible();
  });

  test("archived tab lists archived conversations only", async ({ page, request }) => {
    const archivedTitle = `E2E History Archived ${Date.now()}`;
    await createE2EConversation(request, {
      title: archivedTitle,
      channel_type: "bo",
      status: "archived",
    });

    await gotoBackOfficeLive(page, HISTORY_PATH);
    await expect(page.locator("tr").filter({ hasText: archivedTitle })).not.toBeVisible();

    await page.getByRole("link", { name: "Archived" }).click();
    await waitForLiveViewSettled(page);
    await expect(page).toHaveURL(/\/bo\/history\/archived/);
    await expect(page.locator("tr").filter({ hasText: archivedTitle })).toBeVisible();

    const archivedRow = page.locator("tr").filter({ hasText: archivedTitle });
    await expect(archivedRow.getByRole("button", { name: "Archive" })).toHaveCount(0);

    await page.getByRole("link", { name: "Active" }).click();
    await waitForLiveViewSettled(page);
    await expect(page).toHaveURL(/\/bo\/history$/);
    await expect(page.locator("tr").filter({ hasText: archivedTitle })).not.toBeVisible();
  });

  test("channel filter narrows rows by channel_type", async ({ page, request }) => {
    const mmTitle = `E2E History Mattermost ${Date.now()}`;
    await createE2EConversation(request, {
      title: mmTitle,
      channel_type: "mattermost",
      channel_user_id: "e2e_mm_user",
    });

    await gotoBackOfficeLive(page, HISTORY_PATH);
    await expect(
      page.locator("tr").filter({ hasText: "E2E Unsupported Source Conversation" })
    ).toBeVisible();

    await page.locator("#channel_type").selectOption("mattermost");
    await waitForLiveViewSettled(page);

    await expect(page.locator("tr").filter({ hasText: mmTitle })).toBeVisible();
    await expect(
      page.locator("tr").filter({ hasText: "E2E Unsupported Source Conversation" })
    ).not.toBeVisible();
  });

  test("bulk selection bar and select-all", async ({ page, request }) => {
    const one = `E2E History Bulk One ${Date.now()}`;
    const two = `E2E History Bulk Two ${Date.now()}`;
    await createE2EConversation(request, { title: one, channel_type: "bo" });
    await createE2EConversation(request, { title: two, channel_type: "bo" });

    await gotoBackOfficeLive(page, HISTORY_PATH);
    await page.locator("#channel_type").selectOption("bo");
    await waitForLiveViewSettled(page);

    const rowOne = page.locator("tr").filter({ hasText: one });
    await expect(rowOne).toBeVisible();
    await rowOne.locator('input[type="checkbox"][phx-click="toggle_select"]').check();
    await waitForLiveViewSettled(page);

    await expect(page.getByText("1 selected")).toBeVisible();
    await expect(page.locator('button[phx-click="bulk_archive"]')).toBeVisible();

    await page.locator('thead input[type="checkbox"][phx-click="select_all"]').check();
    await waitForLiveViewSettled(page);

    await expect(page.getByText("3 selected")).toBeVisible();
  });
});
