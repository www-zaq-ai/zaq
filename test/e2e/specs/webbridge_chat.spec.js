const { test, expect, request: apiRequest } = require("@playwright/test");
const {
  loginToBackOffice,
  resetE2EState,
  createE2EAnsweringAgent,
  selectE2EChatAgent,
  waitForLiveViewSettled,
  gotoBackOfficeLive,
  createE2EAiCredential,
  createE2EAgent,
  pickSearchableSelect,
} = require("../support/bo");

async function startNewChat(page, agent) {
  await page.locator("#new-chat-button").click();
  await waitForLiveViewSettled(page);
  await expect(page.locator("#chat-messages")).toContainText("Welcome to ZAQ Chat!");
  await expect(page.locator('[data-testid="chat-assistant-bubble"]')).toHaveCount(1);
  await selectE2EChatAgent(page, agent);
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
  let agent;
  test.beforeAll(async () => {
    const req = await apiRequest.newContext();
    try {
      await resetE2EState(req);
      agent = undefined;
    } finally {
      await req.dispose();
    }
  });

  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    if (!agent) {
      agent = await createE2EAnsweringAgent(page);
      await page.reload();
      await waitForLiveViewSettled(page);
    }
  });

  test("send, resume, citations, message information and new chat preserve BO behavior", async ({ page }) => {
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    await startNewChat(page, agent);
    const question = `WebBridge resume ${Date.now()}`;
    await ask(page, question);

    const answer = page.locator('[data-testid="chat-assistant-bubble"]').last();
    const answerText = await answer.innerText();
    await page.getByRole("button", { name: "Show message information" }).click();
    await expect(page.getByText("Message information", { exact: true })).toBeVisible();
    await expect(page.getByText("Model", { exact: true })).toBeVisible();
    await expect(page.getByText("openai:e2e-fake", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Close", exact: true }).click();

    await startNewChat(page, agent);
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
    await startNewChat(page, agent);
    await startNewChat(other, agent);

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

  test("configured decision tool returns typed answers and alternative probabilities through real BO chat", async ({ page }) => {
    const decisionCredential = await createE2EAiCredential(page, {
      name: `E2E Decision ${Date.now()}`,
      provider: "zaq_router",
      endpoint: "http://127.0.0.1:4002/e2e/llm/v1",
      api_key: "decision-e2e-key",
    });
    await gotoBackOfficeLive(page, "/bo/system-config?tab=global");
    await pickSearchableSelect(page, "#decision-credential-select", decisionCredential.name);
    await pickSearchableSelect(page, "#decision-model-select", "typesafe/jev-1.14");
    await page.locator("#decision-model-form").getByRole("button", { name: "Save Decision Model Settings" }).click();
    await expect(page.getByText("Decision model settings saved.")).toBeVisible();
    const chatCredential = await createE2EAiCredential(page, {
      name: `E2E Decision Chat ${Date.now()}`,
      provider: "custom",
      endpoint: "http://127.0.0.1:4002/e2e/llm/v1",
      api_key: "e2e-fake-key",
    });
    const classifier = await createE2EAgent(page.request, {
      name: `E2E Classifier ${Date.now()}`,
      job: "E2E_DECISION_FLOW: use the decision tool and report its actual result.",
      credential_id: chatCredential.id,
      model: "e2e-fake",
      model_max_context_tokens: 128000,
      enabled_tool_keys: ["general.evaluate_decisions"],
      conversation_enabled: true,
      active: true,
      advanced_options: { stream: true },
    });
    await gotoBackOfficeLive(page, "/bo/chat");
    await startNewChat(page, classifier);
    await page.locator("#chat-input").fill("Please classify a duplicate invoice");
    await page.locator("#chat-form button[type=submit]").click();
    const answer = page.locator('[data-testid="chat-assistant-bubble"]').last();
    await expect(answer).toContainText("Decision result:");
    const result = JSON.parse(await answer.locator("pre code").innerText());
    expect(result).toEqual({
      team: { type: "choice", value: "billing", confidence: null, probabilities: { billing: 0.9, support: 0.1 } },
      refund: { type: "boolean", value: true, probability: 0.8, threshold: 0.5 },
      urgency: { type: "score", value: 0.25, confidence: null, probabilities: { "0": 0.75, "1": 0.25 } },
    });
    await expect(page.getByRole("list", { name: "Tool activity" })).toContainText(/evaluate[_ ]decisions/i);
  });

  test("new chat ignores a late result while the previous conversation still completes", async ({ page, context }) => {
    await loginToBackOffice(page, { returnTo: "/bo/chat" });
    await startNewChat(page, agent);
    const question = `E2E_DELAYED_WEBBRIDGE ${Date.now()}`;
    await page.locator("#chat-input").fill(question);
    let conversationId;
    const history = await context.newPage();
    try {
      await page.locator("#chat-form button[type='submit']").click();
      await expect.poll(async () => {
        const response = await page.request.get("/e2e/llm/pending", { params: { token: question } });
        expect(response.ok()).toBeTruthy();
        return (await response.json()).pending;
      }).toBe(true);
      await expect(page.locator("#chat-messages")).toContainText(question);
      await expect(page.locator('[data-testid="source-chip"]')).toHaveCount(0);
      await startNewChat(page, agent);
      // The sending view refreshes its sidebar on completion. A fresh view can
      // already see the persisted pending conversation; verify its unique question.
      await loginToBackOffice(history, { returnTo: "/bo/chat" });
      const pendingConversation = history.locator('button[phx-click="load_conversation"]').first();
      conversationId = await pendingConversation.getAttribute("phx-value-id");
      await pendingConversation.click();
      await expect(history.locator("#chat-messages")).toContainText(question);
      const released = await page.request.post("/e2e/llm/release", { data: { token: question } });
      expect(released.ok()).toBeTruthy();
    } finally {
      // Also release on assertion failure; the fixture has a bounded timeout as a backstop.
      await page.request.post("/e2e/llm/release", { data: { token: question } });
    }

    // Observe actual finalization from another LiveView, rather than sleeping
    // and allowing a negative assertion to pass before the late result arrives.
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
