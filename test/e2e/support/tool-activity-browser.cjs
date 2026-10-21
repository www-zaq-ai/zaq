const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const fs = require("node:fs")
const path = require("node:path")
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
    const context = await browser.newContext({ baseURL })
    const page = await context.newPage()
    page.on("pageerror", error => errors.push(error.message))
    page.on("console", message => {
      if (message.type() === "error" && message.text().includes("unknown hook")) errors.push(message.text())
    })
    await loginToBackOffice(page, { username: opts.username, password: "StrongPass1!", returnTo: `${baseURL}/bo/chat` })

    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 })
      await page.goto(`${baseURL}/bo/chat`)
      await waitForLiveViewConnected(page)
      if (width === 390 && !(await page.locator("#bo-sidebar").getAttribute("class")).split(/\s+/).includes("collapsed")) {
        await page.getByRole("button", { name: "Toggle sidebar", exact: true }).click()
        await expect(page.locator("#bo-sidebar")).toHaveClass(/\bcollapsed\b/)
      }
      await page.locator("#chat-agent-select-trigger").click()
      await page.locator(`#chat-agent-select [data-select-option][data-select-value='${opts.agent_id}']`).click()
      await waitForLiveViewSettled(page)
      await page.locator("#chat-input").fill(`Tool continuity ${width}`)
      await page.locator("#chat-form").evaluate(form => form.requestSubmit())

      const rows = page.locator("#chat-messages [data-tool-step-id]")
      await expect(rows).toHaveCount(3)
      await expect(rows.nth(2)).toHaveAttribute("data-tool-state", "succeeded")
      await expect(page.locator("#chat-agent-select-trigger")).toBeInViewport()
      try {
        await expect(page.locator("#chat-input")).toBeInViewport()
      } catch (error) {
        fs.mkdirSync(opts.screenshot_dir, { recursive: true })
        await page.screenshot({ path: path.join(opts.screenshot_dir, `tool-activity-layout-${opts.engine}-${width}.png`) })
        console.error(JSON.stringify(await page.evaluate(() => ({ viewport: [innerWidth, innerHeight],
          elements: Object.fromEntries(["#chat-input", ".zaq-chat-page-shell", ".zaq-chat-conversations-sidebar", "#bo-main"].map(selector => {
            const r = document.querySelector(selector).getBoundingClientRect()
            return [selector, { x: r.x, y: r.y, width: r.width, height: r.height }]
          })) }))))
        throw error
      }
      const live = await snapshot(rows)
      expect(live.map(step => step.state)).toEqual(["succeeded", "failed", "succeeded"])
      expect(new Set(live.map(step => step.id)).size).toBe(3)
      await checkpoint("tools-visible")
      await expect(page.locator("#chat-messages")).toContainText("Tool continuity answer")
      // Streaming text can precede finalization; the enabled composer marks the
      // final response, not merely the first visible answer delta.
      await expect(page.locator("#chat-input")).toBeEnabled()
      const saved = await checkpoint("saved")
      expect(saved.steps.map(step => ({ id: step.id, state: step.state }))).toEqual(live.map(({ id, state }) => ({ id, state })))
      expect(await snapshot(rows)).toEqual(live)
      await expect(page.locator("#chat-messages")).not.toContainText("PRIVATE_TOOL_ARGUMENT")

      if (width === 390) {
        const rail = await page.locator(".zaq-chat-conversations-sidebar").boundingBox()
        const header = await page.locator("#chat-agent-select-form").boundingBox()
        expect(rail.y + rail.height).toBeLessThanOrEqual(header.y + 1)
      }
      fs.mkdirSync(opts.screenshot_dir, { recursive: true })
      await page.screenshot({ path: path.join(opts.screenshot_dir, `tool-activity-${opts.engine}-${width}.png`) })

      await page.reload()
      await waitForLiveViewConnected(page)
      await load(page, saved.conversation_id)
      await expect(page.locator("#chat-messages")).toContainText("Tool continuity answer")
      expect(await snapshot(rows)).toEqual(live)
      await expect(page.locator("#chat-messages")).not.toContainText("PRIVATE_TOOL_ARGUMENT")

      await load(page, opts.partial_id)
      await expect(page.locator("#chat-messages")).toContainText("Partial browser answer")
      expect((await snapshot(rows)).map(step => step.state)).toEqual(["succeeded", "unknown"])
      await expect(rows.last().locator("[data-tool-duration]")).toHaveCount(0)
      await load(page, opts.legacy_id)
      await expect(page.locator("#chat-messages")).toContainText("Legacy browser answer")
      await expect(rows).toHaveCount(0)

      // Treat the client as untrusted: tamper only the existing history button's
      // requested ID, then exercise its real server-side authorization boundary.
      const existing = page.locator(`[phx-click='load_conversation'][phx-value-id='${opts.legacy_id}']`)
      await existing.evaluate((button, id) => button.setAttribute("phx-value-id", id), opts.forbidden_id)
      await page.locator(`[phx-click='load_conversation'][phx-value-id='${opts.forbidden_id}']`).click()
      await waitForLiveViewSettled(page)
      await expect(page.locator("#chat-messages")).not.toContainText("FORBIDDEN_HISTORY")
      await expect(rows).toHaveCount(0)

      await checkpoint("revoke")
      await page.reload()
      await waitForLiveViewConnected(page)
      await expect(page.locator(`[phx-click='load_conversation'][phx-value-id='${saved.conversation_id}']`)).toHaveCount(0)
      await expect(rows).toHaveCount(0)
      await expect(page.locator("#chat-messages")).not.toContainText("Tool continuity answer")
      console.log(`${opts.engine}: ${width}px tool continuity passed`)
    }
    expect(errors).toEqual([])
    console.log(`${opts.engine}: history journey passed`)
  } finally {
    await browser.close()
  }
}

async function load(page, id) {
  await page.locator(`[phx-click='load_conversation'][phx-value-id='${id}']`).click()
  await waitForLiveViewSettled(page)
}

async function snapshot(rows) {
  return rows.evaluateAll(elements => elements.map(el => ({
    id: el.dataset.toolStepId,
    state: el.dataset.toolState,
    duration: el.querySelector("[data-tool-duration]")?.textContent.trim() || null
  })))
}

main().then(() => process.exit(0)).catch(error => { console.error(error.stack || error); process.exit(1) })
