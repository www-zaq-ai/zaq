const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const fs = require("node:fs")
const { loginToBackOffice, waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const read = async () => JSON.parse((await lines.next()).value)
  const checkpoint = async stage => {
    console.log(JSON.stringify({ checkpoint: stage }))
    return read()
  }
  const opts = await read()
  const browser = await ({ chromium, firefox, webkit }[opts.engine]).launch()
  const errors = []
  try {
    const context = await browser.newContext({ baseURL: process.argv[2], viewport: { width: 1280, height: 960 } })
    const page = await context.newPage()
    page.on("pageerror", error => errors.push(error.message))
    await loginToBackOffice(page, { username: opts.username, password: "StrongPass1!" })
    const path = `/bo/channels/history/${opts.transcript_id}`
    const answer = page.locator(`#history-message-${opts.answer_id}`)
    const status = answer.locator("[data-testid=delivery-status]")
    await page.goto(path)
    await waitForLiveViewConnected(page)
    await expect(answer.locator("[data-delivery-state=unconfirmed]")).toBeVisible()
    await expect(page.getByText("PRIVATE_TRACE", { exact: true })).toHaveCount(0)
    await expect(page.getByRole("button", { name: /retry|cancel.*message/i })).toHaveCount(0)

    await status.focus()
    const scrollBefore = await page.evaluate(() => scrollY)
    await page.evaluate(id => { window.retainedInput = document.getElementById(`history-message-${id}`) }, opts.input_id)
    await checkpoint("reject")
    await expect(answer.locator("[data-delivery-state=failed]")).toBeVisible()
    expect(await page.evaluate(id => window.retainedInput === document.getElementById(`history-message-${id}`), opts.input_id)).toBe(true)
    await expect(status).toBeFocused()
    expect(await page.evaluate(() => scrollY)).toBe(scrollBefore)
    await page.keyboard.press("Enter")
    const details = page.locator("#channel-delivery-details")
    await expect(details).toContainText("The provider rejected the delivery.")
    await expect(details).toContainText("Provider code 403")
    await expect(details).not.toContainText("PRIVATE_PROVIDER_DETAIL")
    await page.keyboard.press("Escape")
    await expect(details).toHaveCount(0)
    await expect(status).toBeFocused()

    for (const width of [1280, 390]) {
      await viewport(page, width)
      await answer.locator("[phx-click=open_message_info]").click()
      const info = page.locator("[data-testid=message-info-popin]")
      await expect(info).toContainText("Visibility Agent")
      await expect(info).toContainText("fixture-model")
      const displayed = await info.locator("div.flex").evaluateAll(rows => Object.fromEntries(rows.flatMap(row => {
        const spans = Array.from(row.children).filter(el => el.tagName === "SPAN")
        return spans.length === 2 ? [[spans[0].textContent.trim(), spans[1].textContent.trim()]] : []
      })))
      expect(displayed).toEqual({ prompt_tokens: "120", completion_tokens: "30", total_tokens: "150", llm_calls: "2", tool_calls: "1" })
      await info.locator("[data-testid^=trace-row-]").click()
      await expect(info.locator("[data-testid^=trace-details-]")).toContainText("PRIVATE_TRACE")
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
      fs.mkdirSync("test/e2e/test-results", { recursive: true })
      await page.screenshot({ path: `test/e2e/test-results/channel-delivery-${opts.engine}-${width}.png` })
      await info.getByRole("button", { name: "Close", exact: true }).click()
      await expect(info).toHaveCount(0)
    }

    await checkpoint("timeout")
    await expect(answer.locator("[data-delivery-state=unconfirmed]")).toBeVisible()
    await status.click()
    await expect(details).toContainText("timed out")
    await expect(details).toContainText("may have accepted")
    await page.keyboard.press("Escape")
    const late = await checkpoint("incoming")
    await expect(page.locator(`#history-message-${late.input_id}`)).toBeVisible()
    await expect(page.locator(`#history-message-${late.answer_id}`)).toBeVisible()
    await assertPendingLast(page)

    await checkpoint("lost-hint")
    await expect(answer.locator("[data-delivery-state=unconfirmed]")).toBeVisible()
    await page.reload()
    await waitForLiveViewConnected(page)
    await expect(answer.locator("[data-delivery-state=failed]")).toBeVisible()

    const unrelated = await context.newPage()
    await unrelated.goto(`/bo/channels/history/${opts.other_transcript_id}`)
    await waitForLiveViewConnected(unrelated)
    await checkpoint("confirm")
    await expect(answer.locator("[data-delivery-state=history_updating]")).toBeVisible()
    await expect(unrelated.locator(`#history-message-${opts.answer_id}`)).toHaveCount(0)
    await expect(unrelated.locator(`#history-message-${opts.other_answer_id} [data-delivery-state=unconfirmed]`)).toBeVisible()
    await checkpoint("associate")
    await expect(answer.locator("[data-delivery-state]")).toHaveCount(0)
    await expect(answer).toHaveCount(1)
    await checkpoint("duplicate-hint")
    await waitForLiveViewSettled(page)
    await expect(answer).toHaveCount(1)
    await assertPendingLast(page)
    await unrelated.close()

    const pages = await checkpoint("pages")
    await page.goto(`/bo/channels/history/${pages.transcript_id}`)
    await waitForLiveViewConnected(page)
    await expect(page.locator("[data-delivery-state]")).toHaveCount(50)
    await page.getByRole("button", { name: "Load more outstanding messages", exact: true }).click()
    await expect(page.locator("[data-delivery-state]")).toHaveCount(51)
    await checkpoint("page-associate")
    await expect(page.locator("[data-delivery-state]")).toHaveCount(50)
    await expect(page.locator(`#history-message-${pages.answer_id}`)).toHaveCount(0)
    await page.getByRole("link", { name: "Next 50 messages", exact: true }).click()
    await expect(page.locator(`#history-message-${pages.answer_id}`)).toHaveCount(1)
    await expect(page.locator(`#history-message-${pages.answer_id} [data-delivery-state]`)).toHaveCount(0)

    const staffContext = await browser.newContext({ baseURL: process.argv[2] })
    const staffPage = await staffContext.newPage()
    await loginToBackOffice(staffPage, { username: opts.staff_username, password: "StrongPass1!" })
    await staffPage.goto(path)
    await waitForLiveViewConnected(staffPage)
    await expect(staffPage.getByText("Not authorized", { exact: false })).toBeVisible()
    await expect(staffPage.locator("[id^=history-message-]")).toHaveCount(0)
    await staffContext.close()

    await page.goto(path)
    await waitForLiveViewConnected(page)
    await expect(answer).toHaveCount(1)
    await checkpoint("revoke")
    await expect(page.getByText("Not authorized", { exact: false })).toBeVisible()
    await expect(page.locator("[id^=history-message-]")).toHaveCount(0)
    expect(errors).toEqual([])
    console.log(`${opts.engine}: channel delivery history journey passed`)
  } finally {
    await browser.close()
  }
}

async function viewport(page, width) {
  await page.setViewportSize({ width, height: 960 })
  if (width === 390 && !(await page.locator("#bo-sidebar").getAttribute("class")).split(/\s+/).includes("collapsed")) {
    await page.getByRole("button", { name: "Toggle sidebar", exact: true }).click()
    await page.waitForFunction(() => Math.abs(document.getElementById("bo-sidebar").getBoundingClientRect().width - 60) < 1)
  }
}

async function assertPendingLast(page) {
  const pending = await page.locator("[id^=history-message-]").evaluateAll(rows => rows.map(row => Boolean(row.querySelector("[data-delivery-state]"))))
  const firstPending = pending.indexOf(true)
  if (firstPending >= 0) expect(pending.slice(firstPending).every(Boolean)).toBe(true)
}

main().then(() => process.exit(0)).catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
