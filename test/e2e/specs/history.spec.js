const { test, expect } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
  createE2EConversation,
  seedE2EChannelHistory,
} = require("../support/bo");

const HISTORY_PATH = "/bo/history";

async function pickHistorySelect(page, containerId, optionLabel) {
  const container = page.locator(`#${containerId}`);
  await container.locator("[data-select-trigger]").click();
  await container.locator(`[data-select-option="${optionLabel}"]`).click();
  await waitForLiveViewSettled(page);
}

test.describe("BO History page", () => {
  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request);
    await loginToBackOffice(page);
  });

  test("renders filters, admin scope, and table shell", async ({ page }) => {
    await gotoBackOfficeLive(page, HISTORY_PATH);

    await expect(page.locator("#history-status-trigger")).toBeVisible();
    await expect(page.locator("#history-status-trigger")).toContainText("Active");
    await expect(page.locator("#channel_type-trigger")).toBeVisible();

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

  test("archived status lists archived conversations only", async ({ page, request }) => {
    const archivedTitle = `E2E History Archived ${Date.now()}`;
    await createE2EConversation(request, {
      title: archivedTitle,
      channel_type: "bo",
      status: "archived",
    });

    await gotoBackOfficeLive(page, HISTORY_PATH);
    await expect(page.locator("tr").filter({ hasText: archivedTitle })).not.toBeVisible();

    await pickHistorySelect(page, "history-status", "Archived");
    await expect(page).toHaveURL(/\/bo\/history\/archived/);
    await expect(page.locator("tr").filter({ hasText: archivedTitle })).toBeVisible();

    const archivedRow = page.locator("tr").filter({ hasText: archivedTitle });
    await expect(archivedRow.getByRole("button", { name: "Archive" })).toHaveCount(0);

    await pickHistorySelect(page, "history-status", "Active");
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

    await pickHistorySelect(page, "channel_type", "Mattermost");

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
    await pickHistorySelect(page, "channel_type", "BO");

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

test.describe("BO Channel History", () => {
  let fixture;

  test.beforeEach(async ({ page, request }) => {
    await resetE2EState(request);
    fixture = await seedE2EChannelHistory(request);
    await loginToBackOffice(page);
  });

  test("shows passive shared history and inherited thread context", async ({ page }) => {
    await gotoBackOfficeLive(page, "/bo/channels/history");

    const room = page.locator(`#transcript-${fixture.shared_transcript_id}`);
    await expect(room).toContainText("E2E Engineering");
    await expect(room).toContainText("shared");

    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.shared_transcript_id}`);
    await expect(page.getByText("Passive update retained without response")).toBeVisible();
    await expect(page.locator("[data-testid='chat-assistant-bubble']")).toHaveCount(0);

    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.thread_transcript_id}`);
    await expect(page.locator("#thread-root-message")).toContainText(
      "Passive update retained without response"
    );
    await expect(page.locator(`#history-message-${fixture.thread_message_id}`)).toContainText(
      "Thread follow-up"
    );
    await expect(page.locator(`#history-message-${fixture.thread_answer_id}`)).toContainText(
      "Thread answer"
    );
  });

  test("keeps provider access when manual access is revoked and restored", async ({ page }) => {
    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.shared_transcript_id}`);
    await page.getByRole("button", { name: "Manage channel access" }).click();

    const grants = page.locator("#channel-access-grants");
    await expect(grants).toContainText("channel_history:provider:e2e");
    await expect(grants).toContainText(`Person ${fixture.manual_person_id}`);
    const refresh = page.getByRole("button", { name: "Refresh Mattermost membership" });
    await expect(refresh).toBeVisible();
    await refresh.click();
    await expect(
      page.getByText("Provider access unchanged: refresh failed or incomplete")
    ).toBeVisible();
    await expect(grants).toContainText("channel_history:provider:e2e");

    const manualRow = grants.locator("tr").filter({ hasText: `Person ${fixture.manual_person_id}` });
    await manualRow.getByRole("button", { name: "Revoke manual" }).click();
    await waitForLiveViewSettled(page);
    await expect(grants).toContainText("channel_history:provider:e2e");
    await expect(grants).not.toContainText(`Person ${fixture.manual_person_id}`);

    await page.locator("#channel-history-person").fill(String(fixture.manual_person_id));
    await page.getByRole("button", { name: "Grant read access" }).click();
    await waitForLiveViewSettled(page);
    await expect(grants).toContainText(`Person ${fixture.manual_person_id}`);
    await expect(grants).toContainText("manual");

    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.replicated_transcript_id}`);
    await page.getByRole("button", { name: "Manage channel access" }).click();
    await expect(page.getByText(/Provider membership refresh is unsupported/)).toBeVisible();
  });

  test("presents merged replica ownership and restricted legacy evidence", async ({ page }) => {
    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.replicated_transcript_id}`);
    await expect(page.getByText(`Recipient: ${fixture.replica_owner_name}`)).toBeVisible();
    await expect(page.getByText("Recipient-specific answer")).toBeVisible();
    await expect(page.getByText("invoice.pdf")).toBeVisible();
    await expect(
      page.locator(
        `#history-message-${fixture.replicated_message_id} [data-reaction-type='positive']`
      )
    ).toContainText("2");

    await gotoBackOfficeLive(page, `/bo/channels/history/${fixture.legacy_transcript_id}`);
    await expect(page.getByText(/Restricted legacy snapshot/)).toBeVisible();
    await expect(page.getByText("Legacy answer with preserved evidence")).toBeVisible();
    await expect(page.getByText("legacy-report.pdf")).toBeVisible();

    await page
      .locator(
        `#history-message-${fixture.legacy_message_id} button[phx-click='open_message_info']`
      )
      .click();
    await expect(page.getByTestId("message-info-popin")).toBeVisible();
    await expect(page.getByText("legacy-search")).toBeVisible();
  });

  test("denies transcript inspection to a non-super-admin", async ({ page }) => {
    await loginToBackOffice(page, {
      username: fixture.viewer_username,
      password: fixture.viewer_password,
      realLogin: true,
      returnTo: `/bo/channels/history/${fixture.shared_transcript_id}`,
    });

    await expect(page.getByText("Not authorized")).toBeVisible();
    await expect(
      page.getByText("Only a current BO super-admin can inspect all channel transcripts.")
    ).toBeVisible();
    await expect(page.getByText("Passive update retained without response")).not.toBeVisible();
  });
});
