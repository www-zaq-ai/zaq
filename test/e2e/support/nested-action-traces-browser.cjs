const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const { loginToBackOffice, waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const read = async () => JSON.parse((await lines.next()).value)
  const checkpoint = async stage => { console.log(JSON.stringify({ checkpoint: stage })); return read() }
  const opts = await read()
  const baseURL = process.argv[2]
  const browser = await ({ chromium, firefox, webkit }[opts.engine]).launch()
  const errors = []

  try {
    const page = await browser.newPage({ baseURL, viewport: { width: 1280, height: 1000 } })
    page.on("pageerror", error => errors.push(error.message))
    await loginToBackOffice(page, { username: opts.username, password: "StrongPass1!", returnTo: `${baseURL}/bo/chat` })
    await page.locator("#chat-agent-select-trigger").click()
    await page.locator(`#chat-agent-select [data-select-option][data-select-value='${opts.agent_id}']`).click()
    await waitForLiveViewSettled(page)
    await page.locator("#chat-input").fill("Find nestedneedle")
    await page.locator("#chat-form").evaluate(form => form.requestSubmit())
    await expect(page.locator("#chat-messages")).toContainText("Nested trace answer")
    await expect(page.locator("#chat-input")).toBeEnabled()
    const saved = await checkpoint("agent-saved")
    await inspectAgent(page, saved)
    await page.reload()
    await waitForLiveViewConnected(page)
    await page.locator(`[phx-click='load_conversation'][phx-value-id='${saved.conversation_id}']`).click()
    await waitForLiveViewSettled(page)
    await inspectAgent(page, saved)
    await page.getByRole("button", { name: "Close", exact: true }).click()

    await checkpoint("trace-role-revoke")
    await page.reload()
    await waitForLiveViewConnected(page)
    await page.locator(`[phx-click='load_conversation'][phx-value-id='${saved.conversation_id}']`).click()
    await waitForLiveViewSettled(page)
    await page.getByRole("button", { name: "Show message information" }).last().click()
    const publicInfo = page.locator('[data-testid="message-info-popin"]')
    await expect(publicInfo.locator('[data-testid^="trace-row-"]')).toHaveCount(1)
    await expect(publicInfo.locator(`[data-testid='trace-row-${saved.child_id}']`)).toHaveCount(0)
    await page.getByRole("button", { name: "Close", exact: true }).click()
    await expect(page.locator("#chat-messages [data-tool-step-id]")).toHaveCount(1)

    // Exercise the real history authorization boundary with an untrusted client ID.
    const load = page.locator(`[phx-click='load_conversation'][phx-value-id='${saved.conversation_id}']`)
    await load.evaluate((button, id) => button.setAttribute("phx-value-id", id), opts.forbidden_id)
    await page.locator(`[phx-click='load_conversation'][phx-value-id='${opts.forbidden_id}']`).click()
    await waitForLiveViewSettled(page)
    await expect(page.locator("#chat-messages")).not.toContainText("FORBIDDEN_NESTED_HISTORY")
    await checkpoint("trace-role-restore")

    for (const mode of ["complete", "cancel"]) {
      const run = await checkpoint(`workflow-${mode}-start`)
      await page.goto(`${baseURL}/bo/workflows/${run.workflow_id}/runs/${run.run_id}`)
      await waitForLiveViewConnected(page)
      // Mount preselects the active step; clicking it here would toggle it off.
      const panel = page.locator(`[data-testid='workflow-action-traces-${run.step_id}']`)
      await expect(panel).toBeVisible()
      await inspectWorkflow(panel, run, "Running")
      await panel.locator(`[data-testid='trace-row-${run.nested_id}']`).click()
      await expect(panel.locator(`[data-testid='trace-details-${run.nested_id}']`)).toContainText('"value": 42')
      await panel.locator(`[data-testid='trace-row-${run.sibling_id}']`).click()
      await expect(panel.locator(`[data-testid='trace-details-${run.sibling_id}']`)).toContainText("[REDACTED]")
      await expect(panel).not.toContainText("PRIVATE_CHILD_ARGUMENT")

      if (mode === "complete") {
        await checkpoint("workflow-complete-release")
        await inspectWorkflow(panel, run, "Succeeded")
        await expect(panel.locator(`[data-testid='trace-details-${run.sibling_id}']`)).toContainText('"value": 42')
        await expect(panel.locator(`[data-testid='trace-details-${run.sibling_id}']`)).toContainText("[REDACTED]")
        await expect(panel).not.toContainText("PRIVATE_CHILD_RESULT")
      } else {
        await page.locator('[phx-click="cancel_run"]').click()
        await expect(page.locator('[phx-click="cancel_run"]')).toHaveCount(0)
        await checkpoint("workflow-cancelled")
        await inspectWorkflow(panel, run, "Unknown")
      }

      await page.reload()
      await waitForLiveViewConnected(page)
      await page.locator('[phx-click="select_step"][phx-value-step_name="review"]').click()
      await inspectWorkflow(page.locator(`[data-testid='workflow-action-traces-${run.step_id}']`), run, mode === "complete" ? "Succeeded" : "Unknown")
      await page.locator(`[data-testid='trace-row-${run.sibling_id}']`).click()
      await expect(page.locator(`[data-testid='trace-details-${run.sibling_id}']`)).toContainText("[REDACTED]")
      if (mode === "complete") {
        await expect(page.locator(`[data-testid='trace-details-${run.sibling_id}']`)).toContainText('"value": 42')
      }
      await expect(page.locator("body")).not.toContainText("PRIVATE_CHILD_ARGUMENT")
      await expect(page.locator("body")).not.toContainText("PRIVATE_CHILD_RESULT")
    }

    expect(errors).toEqual([])
    console.log(`${opts.engine}: nested agent/workflow history journey passed`)
  } finally {
    await browser.close()
  }
}

async function inspectAgent(page, saved) {
  const roots = page.locator("#chat-messages [data-tool-step-id]")
  await expect(roots).toHaveCount(1)
  await expect(roots).toHaveAttribute("data-tool-step-id", "opaque.native.root")
  await page.getByRole("button", { name: "Show message information" }).last().click()
  const panel = page.locator('[data-testid="message-info-popin"]')
  await expect(panel).toBeVisible()
  const child = panel.locator(`[data-testid='trace-row-${saved.child_id}']`)
  await expect(child).toContainText("Succeeded")
  await expect(child.locator("..")).toHaveAttribute("data-trace-depth", "1")
  await child.click()
  await expect(panel.locator(`[data-testid='trace-details-${saved.child_id}']`)).toContainText('"invocation_path"')
  await expect(panel.locator(`[data-testid='trace-details-${saved.child_id}']`)).toContainText("opaque.native.root")
}

async function inspectWorkflow(panel, run, siblingOutcome) {
  await expect(panel.locator(`[data-testid='trace-row-${run.branch_id}']`)).toContainText("Succeeded")
  const nested = panel.locator(`[data-testid='trace-row-${run.nested_id}']`)
  await expect(nested).toContainText("Succeeded")
  await expect(nested.locator("..")).toHaveAttribute("data-trace-depth", "1")
  const sibling = panel.locator(`[data-testid='trace-row-${run.sibling_id}']`)
  await expect(sibling).toContainText(siblingOutcome)
  await expect(sibling.locator("..")).toHaveAttribute("data-trace-depth", "0")
}

main().then(() => process.exit(0)).catch(error => { console.error(error.stack || error); process.exit(1) })
