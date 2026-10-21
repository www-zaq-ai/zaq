const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const fs = require("node:fs")
const path = require("node:path")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const read = async () => JSON.parse((await lines.next()).value)
  const checkpoint = async stage => { console.log(JSON.stringify({ checkpoint: stage })); return read() }
  const opts = await read()
  const host = process.argv[2]
  const browser = await ({ chromium, firefox, webkit }[opts.engine]).launch()
  const errors = []
  let page
  try {
    const context = await browser.newContext({ viewport: { width: opts.reconnect ? 390 : 1280, height: 900 } })
    page = await context.newPage()
    const observe = target => {
      target.on("pageerror", error => errors.push(error.message))
      target.on("console", message => {
        // Firefox reports target-origin mismatches while an iframe is still
        // about:blank. Capture application failures, not those preload diagnostics.
        if (message.type() === "error" && (message.text().startsWith("[WebWidget]") || message.text().includes("unknown hook"))) errors.push(message.text())
      })
    }
    observe(page)
    const open = async (target, id) => {
      await target.goto(`${opts.parent_origin}/?widget=${id}&host=${encodeURIComponent(host)}`)
      const frame = target.frameLocator("iframe")
      await expect(frame.getByRole("textbox")).toBeEditable({ timeout: 20000 })
      return frame
    }
    if (opts.scenario === "isolation") {
      const pages = [page, await page.context().newPage()]
      observe(pages[1])
      const frames = await Promise.all(pages.map((target, i) => open(target, opts.widgets[i].widget_id)))
      await Promise.all(frames.map(async (frame, i) => {
        await frame.getByRole("textbox").fill(opts.widgets[i].prompt)
        await frame.getByRole("textbox").press("Enter")
        await expect(frame.locator("[data-step-id][data-kind='tool_call']")).toHaveCount(1, { timeout: 20000 })
      }))
      await checkpoint("concurrent")
      for (let i = 0; i < 2; i++) {
        await expect(frames[i].getByText(opts.widgets[i].answer, { exact: true })).toBeVisible({ timeout: 20000 })
        await expect(frames[i].locator("[data-role='assistant']")).toHaveAttribute("data-running", "false")
        await expect(frames[i].locator("body")).not.toContainText(opts.widgets[1 - i].answer)
        await expect(frames[i].locator("body")).not.toContainText(opts.widgets[1 - i].prompt)
      }
      const saved = await checkpoint("isolated-saved")
      for (let i = 0; i < 2; i++) {
        await pages[i].reload()
        await expect.poll(() => pages[i].evaluate(() => window.zaq?.widget.isReady())).toBe(true)
        const restored = await pages[i].evaluate(id => window.zaq.widget.updateContext({ conversation_id: id }), saved.answers[i].conversation_id)
        expect(restored.ok).toBe(true)
        await expect(frames[i].getByText(opts.widgets[i].answer, { exact: true })).toBeVisible()
        await expect(pages[i].evaluate(id => window.zaq.widget.updateContext({ conversation_id: id }), saved.answers[1 - i].conversation_id)).rejects.toThrow("The requested conversation could not be opened.")
        await expect(frames[i].locator("body")).not.toContainText(opts.widgets[1 - i].answer)
      }
      expect(errors).toEqual([])
      console.log("history journey passed")
      return
    }
    await open(page, opts.widget_id)
    const widget = page.frameLocator("iframe")
    const composer = widget.getByRole("textbox")
    await expect(composer).toBeEditable({ timeout: 20000 })
    if (opts.scenario === "rejection") await checkpoint("revoke-sender")
    await composer.fill("Please add 2 and 3")
    await composer.press("Enter")
    if (opts.scenario === "rejection") {
      await expect(widget.locator(".zaq-widget-error")).toBeVisible({ timeout: 20000 })
      await expect(composer).toHaveValue("Please add 2 and 3")
      await expect(widget.locator("[data-role='assistant']")).toHaveCount(0)
      expect(errors).toEqual([])
      await checkpoint("rejected")
      console.log("history journey passed")
      return
    }
    if (opts.scenario === "no-answer") {
      await expect(widget.locator("[data-role='user']")).toHaveCount(1)
      await expect(composer).toHaveValue("")
      await checkpoint("no-answer")
      await expect(widget.locator("[data-role='assistant']")).toHaveCount(0)
      await expect(widget.locator(".zaq-working")).toHaveCount(0)
      expect(errors).toEqual([])
      console.log("history journey passed")
      return
    }
    const tools = widget.locator("[data-step-id][data-kind='tool_call']")
    await expect(tools).toHaveCount(1, { timeout: 20000 })
    await expect(tools.first()).toHaveAttribute("data-status", "complete")
    await expect(widget.locator(".zaq-working")).toBeVisible()
    const invocation = await tools.first().getAttribute("data-step-id")
    if (opts.scenario === "interruption") {
      if (opts.partial) await expect(widget.locator(".zaq-answer-content")).toContainText("Partial answer already shown.", { timeout: 20000 })
      await checkpoint("interrupt")
      await expect(widget.locator("[data-role='assistant']")).toHaveAttribute("data-running", "false", { timeout: 20000 })
      await checkpoint("settled")
      await page.evaluate(() => window.zaq.widget.getSettings())
      await expect(widget.locator(".zaq-response-error")).toBeVisible()
      if (opts.partial) await expect(widget.locator(".zaq-answer-content")).toContainText("Partial answer already shown.")
      await expect(widget.locator("[data-role='assistant']")).toHaveCount(1)
      await expect(widget.locator(".zaq-working")).toHaveCount(0)
      await expect(tools.first()).toHaveAttribute("data-step-id", invocation)
      await expect(tools.first()).toHaveAttribute("data-status", "complete")
      await expect(widget.locator("body")).not.toContainText("This result must never be delivered.")
      expect(errors).toEqual([])
      console.log("history journey passed")
      return
    }
    const accepted = await checkpoint("tools-visible")
    if (opts.reconnect) {
      // Destroy the original LiveView while the native request is still held.
      await page.reload()
      await expect(widget.getByRole("textbox")).toBeEditable({ timeout: 20000 })
      await expect.poll(() => page.evaluate(() => window.zaq?.widget.isReady())).toBe(true)
      const result = await page.evaluate(id => window.zaq.widget.updateContext({ conversation_id: id }), accepted.conversation_id)
      expect(result.ok).toBe(true)
      await checkpoint("resumed")
    }
    await expect(widget.getByText("The real sum is 5.", { exact: true })).toBeVisible({ timeout: 20000 })
    await expect(widget.locator("[data-role='assistant']")).toHaveAttribute("data-running", "false")
    await expect(widget.locator(".zaq-working")).toHaveCount(0)
    const saved = await checkpoint("saved")
    expect(saved.answer_id).toBeTruthy()
    expect(saved.steps[0].id).toBe(invocation)
    const duration = await tools.first().textContent()
    await page.reload()
    await expect(widget.getByRole("textbox")).toBeEditable({ timeout: 20000 })
    await expect.poll(() => page.evaluate(() => window.zaq?.widget.isReady())).toBe(true)
    const restored = await page.evaluate(id => window.zaq.widget.updateContext({ conversation_id: id }), saved.conversation_id)
    expect(restored.ok).toBe(true)
    await expect(widget.getByText("The real sum is 5.", { exact: true })).toBeVisible()
    await expect(widget.locator("[data-role='assistant']")).toHaveCount(1)
    await expect(widget.locator("[data-role='user']")).toHaveCount(1)
    await expect(tools).toHaveCount(1)
    await expect(tools.first()).toHaveAttribute("data-step-id", invocation)
    await expect(tools.first()).toHaveAttribute("data-status", "complete")
    expect(await tools.first().textContent()).toBe(duration)
    expect(errors).toEqual([])
    console.log("history journey passed")
  } catch (error) {
    const directory = "test/e2e/test-results"
    fs.mkdirSync(directory, { recursive: true })
    const scenario = opts.scenario || (opts.reconnect ? "reconnect" : "success")
    await page?.screenshot({ path: path.join(directory, `widget-lifecycle-${opts.engine}-${scenario}-${!!opts.partial}.png`) }).catch(() => {})
    console.error(JSON.stringify({ errors, frames: await Promise.all((page?.frames() || []).map(async frame => ({ url: frame.url().split("#")[0], text: await frame.locator("body").innerText().catch(() => "unavailable") }))) }))
    throw error
  } finally {
    await browser.close()
    process.stdin.destroy()
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; process.stdin.destroy() })
