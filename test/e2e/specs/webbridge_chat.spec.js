const { test, expect, request: apiRequest } = require("@playwright/test");
const {
  loginToBackOffice,
  resetE2EState,
  setE2ESystemConfig,
  waitForLiveViewSettled,
} = require("../support/bo");

async function startNewChat(page) {
  await page.locator("#new-chat-button").click();
  await waitForLiveViewSettled(page);
  await expect(page.locator("#chat-messages")).toContainText("Welcome to ZAQ Chat!");
  await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(1);
}

async function ask(page, question) {
  await page.locator("#chat-input").fill(question);
  await page.locator("#chat-form button[type='submit']").click();
  await expect(page.locator("#chat-messages")).toContainText(question);
  await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(2);
  await expect(page.locator('[data-testid="source-chip"]').first()).toBeVisible();
  await waitForLiveViewSettled(page);
}

test.describe("Shared WebBridge BO chat", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext();
    try {
      await resetE2EState(req);
      // Match the chat journeys' budget for the real prompt and tool schemas.
      await setE2ESystemConfig(req, "llm.max_context_window", "128000");
    } finally {
      await req.dispose();
    }
  });

  test("send, resume, citations, message information and new chat preserve BO behavior", async ({ page }) => {
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    await startNewChat(page);
    const question = `WebBridge resume ${Date.now()}`;
    await ask(page, question);

    const answer = page.locator('[data-testid="chat-assistant-bubble"]').last();
    const answerText = await answer.innerText();
    await page.getByRole("button", { name: "Show message information" }).click();
    await expect(page.getByText("Message information", { exact: true })).toBeVisible();
    await expect(page.getByText("Model", { exact: true })).toBeVisible();
    await expect(page.getByText("openai:e2e-fake", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Close", exact: true }).click();

    await startNewChat(page);
    await expect(page.locator("#chat-messages")).not.toContainText(question);
    await page.locator('button[phx-click="load_conversation"]').first().click();
    await waitForLiveViewSettled(page);
    await expect(page.locator("#chat-messages")).toContainText(question);
    await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(2);
    await expect(page.locator('[data-testid="chat-assistant-bubble"]').last()).toContainText(answerText);
  });

  test("two live sessions receive only their own request results", async ({ page, context }) => {
    const other = await context.newPage();
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    await loginToBackOffice(other, { returnTo: "/bo/chat" });
    await startNewChat(page);
    await startNewChat(other);

    const question = `WebBridge isolated ${Date.now()}`;
    await ask(page, question);
    await expect(other.locator("#chat-messages")).not.toContainText(question);
    await expect(other.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(1);

    const otherQuestion = `WebBridge second session ${Date.now()}`;
    await ask(other, otherQuestion);
    await expect(page.locator("#chat-messages")).not.toContainText(otherQuestion);
    await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(2);
    await other.close();
  });

  test("new chat ignores a late result while the previous conversation still completes", async ({ page, context }) => {
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    await startNewChat(page);
    const question = `E2E_DELAYED_WEBBRIDGE ${Date.now()}`;
    await page.locator("#chat-input").fill(question);
    await page.locator("#chat-form button[type='submit']").click();
    await expect(page.locator("#chat-messages")).toContainText(question);
    await expect(page.locator('[data-testid="source-chip"]')).toHaveCount(0);
    const conversationId = await page.locator('button[phx-click="load_conversation"][aria-current="page"]').getAttribute("phx-value-id");
    await startNewChat(page);

    // Observe actual finalization from another LiveView, rather than sleeping
    // and allowing a negative assertion to pass before the late result arrives.
    const history = await context.newPage();
    await loginToBackOffice(history, { returnTo: "/bo/chat" });
    await expect(async () => {
      await history.reload();
      await waitForLiveViewSettled(history);
      await history.locator(`button[phx-click="load_conversation"][phx-value-id="${conversationId}"]`).click();
      await expect(history.locator("#chat-messages")).toContainText(question);
      await expect(history.locator('[data-testid="source-chip"]').first()).toBeVisible({ timeout: 1_000 });
    }).toPass({ timeout: 20_000 });

    await waitForLiveViewSettled(page);
    await expect(page.locator("#chat-messages")).not.toContainText(question);
    await expect(page.locator('[data-testid="source-chip"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(1);
    await expect(page.locator("#chat-messages")).toContainText("Welcome to ZAQ Chat!");
    await history.close();
  });
});
