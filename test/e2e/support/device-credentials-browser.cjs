const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const { waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const lines = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const [baseURL, engine, username, fixturesJSON] = process.argv.slice(2)
  const browser = await ({ chromium, firefox, webkit }[engine]).launch()
  try {
    for (const fixture of JSON.parse(fixturesJSON)) {
      const context = await browser.newContext({ viewport: { width: fixture.width, height: 900 } })
      const page = await context.newPage()
      const errors = []
      page.on("pageerror", error => errors.push(error.message))
      // Provider page is intercepted in the browser, not contacted over the network.
      await context.route("https://auth.openai.com/**", route => route.fulfill({
        contentType: "text/html", body: "<h1>Provider device sign-in</h1>"
      }))
      await page.goto(`${baseURL}/bo/login`)
      await waitForLiveViewConnected(page)
      await page.locator("[name=username]").fill(username)
      await waitForLiveViewSettled(page)
      await page.locator("[name=password]").fill("ValidPass123!")
      await waitForLiveViewSettled(page)
      await page.locator("#bo-login-form button[type=submit]").click()
      await expect(page).toHaveURL(/\/bo\/dashboard$/)

      for (const surface of ["bo", "people"]) {
        const bo = surface === "bo"
        if (bo) {
          await page.goto(`${baseURL}/bo/system-config?tab=ai_credentials`)
        } else {
          await page.goto(`${baseURL}/people/login`)
          await waitForLiveViewConnected(page)
          await page.getByLabel("Email address").fill(fixture.email)
          await page.getByRole("button", { name: "Send sign-in code" }).click()
          const code = (await lines.next()).value
          await page.getByLabel("One-time code").fill(code)
          await page.getByRole("button", { name: "Sign in", exact: true }).click()
          await expect(page).not.toHaveURL(/\/people\/login/)
          await page.goto(`${baseURL}/people/credentials`)
        }
        await waitForLiveViewConnected(page)
        const open = async () => {
          if (bo) await page.locator(`[phx-click=edit_ai_credential][phx-value-id="${fixture.ai_id}"]`).click()
          else await page.locator(`#credential-edit-${fixture.connect_id}`).click()
        }
        await open()
        const prefix = bo ? "ai" : "people"
        const start = page.locator(bo ? "#ai-device-connect" : `#credential-device-${fixture.connect_id}`)
        const instructions = page.locator(`#${prefix}-device-sign-in`)
        const code = page.locator(`#${prefix}-device-sign-in-code`)
        const begin = async () => {
          await start.click()
          await expect(code).toHaveText("BROWSER-CODE")
          await expect(instructions).toContainText("Waiting for approval")
          const link = page.locator(`#${prefix}-device-sign-in-open`)
          await expect(link).toHaveAttribute("href", "https://auth.openai.com/codex/device")
          await expect(link).toHaveAttribute("target", "_blank")
          await expect(link).toHaveAttribute("rel", "noopener noreferrer")
          const box = await link.boundingBox()
          expect(box.x).toBeGreaterThanOrEqual(0)
          expect(box.x + box.width).toBeLessThanOrEqual(fixture.width)
          const html = await page.content()
          expect(html).not.toContain("BROWSER-ACCESS-SECRET")
          expect(html).not.toContain("BROWSER-REFRESH-SECRET")
          expect(html).not.toContain("BROWSER-VERIFIER")
        }
        const checkpoint = async action => {
          console.log("device-checkpoint:" + JSON.stringify({
            action, credential_id: fixture.connect_id, owner_type: bo ? "org" : "person"
          }))
          expect((await lines.next()).value).toBe("checkpoint-ready")
        }
        await begin()
        const popupPromise = page.waitForEvent("popup")
        await page.locator(`#${prefix}-device-sign-in-open`).click()
        const popup = await popupPromise
        await expect(popup.getByRole("heading")).toHaveText("Provider device sign-in")
        expect(await popup.evaluate(() => window.opener === null)).toBe(true)
        await popup.close()
        await page.screenshot({ path: `test/e2e/test-results/device-${surface}-${engine}-${fixture.width}.png`, fullPage: true })
        // Browser disconnect/reload observes the existing attempt; it does not cancel it.
        await page.reload()
        await waitForLiveViewConnected(page)
        await open()
        await expect(code).toHaveText("BROWSER-CODE")
        await page.locator(`[phx-click=${bo ? "cancel_ai_device" : "cancel_device"}]`).click()
        await expect(instructions).toContainText("Device sign-in cancelled")
        await expect(code).toHaveCount(0)
        await begin()
        await checkpoint("expire")
        await expect(instructions).toContainText("code expired")
        await expect(code).toHaveCount(0)
        await begin()
        await checkpoint("interrupt")
        await expect(instructions).toContainText("previous flow cannot resume")
        await expect(code).toHaveCount(0)
        await begin()
        await checkpoint("approve")
        await expect(instructions).toContainText("Device sign-in completed")
        await expect(code).toHaveCount(0)
        expect(await page.content()).not.toContain("BROWSER-ACCESS-SECRET")
      }
      expect(errors).toEqual([])
      await context.close()
      console.log(`${engine}: ${fixture.width}px passed`)
    }
  } finally {
    await browser.close()
  }
}
main().then(() => process.exit(0)).catch(error => { console.error(error); process.exit(1) })
