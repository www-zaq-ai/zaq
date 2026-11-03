const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const { loginToBackOffice, pickSearchableSelect, waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const read = async () => JSON.parse((await lines.next()).value)
  const checkpoint = async stage => { console.log(JSON.stringify({ checkpoint: stage })); return read() }
  const opts = await read()
  const baseURL = process.argv[2]
  const browser = await ({ chromium, firefox, webkit }[opts.engine]).launch()
  try {
    const context = await browser.newContext({ baseURL, viewport: { width: 1280, height: 900 } })
    const page = await context.newPage()
    await loginToBackOffice(page, { username: opts.username, password: "StrongPass1!", returnTo: `${baseURL}/bo/system-config?tab=global` })
    const global = page.locator("#global-default-agent-select")
    await expect(global).toContainText("None")
    await expect(global).not.toContainText("Default Zaq Agent")
    await pickSearchableSelect(page, "#global-default-agent-select", opts.agent_name, { searchable: false })
    await page.locator("form[phx-submit='save_global_default_agent']").evaluate(form => form.requestSubmit())
    await waitForLiveViewSettled(page)
    await page.reload()
    await waitForLiveViewConnected(page)
    await expect(page.locator("#global-default-agent-select-trigger")).toContainText(opts.agent_name)

    await page.goto(`${baseURL}/bo/chat`)
    await waitForLiveViewConnected(page)
    await expect(page.locator("#chat-agent-select-trigger")).toContainText("Default (routing)")
    await expect(page.locator("#chat-agent-select")).not.toContainText("Default pipeline")
    await ask(page, "Find routingneedle using inherited routing")
    await checkpoint("inherited-answer")

    await page.goto(`${baseURL}/bo/system-config?tab=global`)
    await waitForLiveViewConnected(page)
    await pickSearchableSelect(page, "#global-default-agent-select", "None", { searchable: false })
    await page.locator("form[phx-submit='save_global_default_agent']").evaluate(form => form.requestSubmit())
    await waitForLiveViewSettled(page)
    await page.reload()
    await waitForLiveViewConnected(page)
    await expect(page.locator("#global-default-agent-select-trigger")).toContainText("None")
    await checkpoint("global-none")

    // A deliberate configured selection still works even when the root is None.
    await page.goto(`${baseURL}/bo/chat`)
    await waitForLiveViewConnected(page)
    await page.getByRole("button", { name: "New", exact: true }).click()
    await waitForLiveViewSettled(page)
    await pickSearchableSelect(page, "#chat-agent-select", opts.agent_name, { searchable: false })
    await ask(page, "Find routingneedle using explicit selection")
    await checkpoint("explicit-answer")

    // Keep the mounted selection stale while deleting the actual stored agent.
    await checkpoint("delete-selected")
    const answersBeforeDeletion = await page.getByTestId("chat-assistant-bubble").count()
    await page.locator("#chat-input").fill("Deleted selection must not start a hidden fallback")
    await page.locator("#chat-form").evaluate(form => form.requestSubmit())
    await expect(page.locator("#chat-messages")).toContainText("Deleted selection must not start a hidden fallback")
    await waitForLiveViewSettled(page)
    await expect(page.locator("#chat-input")).toBeEnabled()
    await expect(page.getByTestId("chat-assistant-bubble")).toHaveCount(answersBeforeDeletion)
    await checkpoint("deleted-selection")

    await page.goto(`${baseURL}/bo/chat`)
    await waitForLiveViewConnected(page)
    await expect(page.locator(`#chat-agent-select [data-select-value='${opts.agent_id}']`)).toHaveCount(0)
    await page.getByRole("button", { name: "New", exact: true }).click()
    await waitForLiveViewSettled(page)
    await expect(page.locator("#chat-agent-select-trigger")).toContainText("Default (routing)")
    const answersBeforeUnassigned = await page.getByTestId("chat-assistant-bubble").count()
    await page.locator("#chat-input").fill("Unassigned route must not invent an agent")
    await page.locator("#chat-form").evaluate(form => form.requestSubmit())
    await expect(page.locator("#chat-messages")).toContainText("Unassigned route must not invent an agent")
    await waitForLiveViewSettled(page)
    await expect(page.locator("#chat-input")).toBeEnabled()
    await expect(page.getByTestId("chat-assistant-bubble")).toHaveCount(answersBeforeUnassigned)
    await expect(page.locator("#chat-messages")).not.toContainText("Configured routing evidence delivered.")
    await checkpoint("no-fallback")

    await page.goto(`${baseURL}/bo/ai-diagnostics`)
    await waitForLiveViewConnected(page)
    await expect(page.locator("button[phx-click='test_llm']")).toHaveCount(0)
    await expect(page.locator("button[phx-click='test_embedding']")).toBeVisible()
    console.log(`${opts.engine}: history journey passed`)
  } finally {
    await browser.close()
  }
}

async function ask(page, question) {
  await page.locator("#chat-input").fill(question)
  await page.locator("#chat-form").evaluate(form => form.requestSubmit())
  await expect(page.locator("#chat-messages")).toContainText("Configured routing evidence delivered.", { timeout: 15000 })
  await expect(page.locator("#chat-input")).toBeEnabled()
}

main().then(() => process.exit(0)).catch(error => { console.error(error.stack || error); process.exit(1) })
