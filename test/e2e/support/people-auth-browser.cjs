const { chromium, firefox, webkit, expect } = require("@playwright/test")
const readline = require("node:readline")
const { waitForLiveViewConnected, waitForLiveViewSettled } = require("./bo")

async function main() {
  const codes = readline.createInterface({ input: process.stdin })[Symbol.asyncIterator]()
  const [baseURL, engine, suffix, username] = process.argv.slice(2)
  const browser = await ({ chromium, firefox, webkit }[engine]).launch()
  try {
    for (const width of [390, 1280]) {
    const context = await browser.newContext({ viewport: { width, height: 844 } })
    const page = await context.newPage()
    const email = `${suffix}-${width}@example.test`
    const boLogin = async () => {
      await page.goto(`${baseURL}/bo/login`)
      await page.locator("#bo-login-form").waitFor()
      await waitForLiveViewConnected(page)
      await page.locator("[name=username]").fill(username)
      await waitForLiveViewSettled(page)
      await page.locator("[name=password]").fill("ValidPass123!")
      await waitForLiveViewSettled(page)
      await page.locator("#bo-login-form button[type=submit]").click()
      await expect(page).toHaveURL(/\/bo\/dashboard$/)
      await page.goto(`${baseURL}/bo/profile`)
      await expect(page).toHaveURL(/\/bo\/profile$/)
      await expect(page.getByRole("heading", { name: "My Profile", exact: true })).toBeVisible()
    }
    const errors = []
    page.on("pageerror", error => errors.push(error.message))
    if (width === 390) await boLogin()
    await page.goto(`${baseURL}/people/login`)
    await expect(page).toHaveTitle("Sign in · ZAQ")
    await page.locator(".phx-connected").waitFor()
    await expect(page.getByLabel("Email address")).toBeVisible()
    await page.getByLabel("Email address").fill(email)
    await page.getByRole("button", { name: "Send sign-in code" }).click()
    const first = (await codes.next()).value
    await page.locator(".phx-connected").waitFor()
    await expect(page.getByLabel("One-time code")).toBeVisible()
    const wrong = `${first[0] === "0" ? "1" : "0"}${first.slice(1)}`
    await page.getByLabel("One-time code").fill(wrong)
    await page.getByRole("button", { name: "Sign in", exact: true }).click()
    await expect(page.getByRole("alert")).toContainText("incorrect or has expired")
    await expect(page.getByLabel("One-time code")).toHaveValue("")
    await page.locator(".phx-connected").waitFor()
    await page.clock.install()
    // Move wall time only: fast-forwarding every timer also expires LiveSocket
    // heartbeat/fallback timers and tests transport failure rather than the UI.
    await page.clock.setSystemTime(new Date(Date.now() + 301000))
    await expect(page.locator("[data-countdown]")).toContainText("Code expired")
    await expect(page.getByRole("button", { name: "Resend code" })).toBeEnabled()
    await page.clock.setSystemTime(new Date())
    await page.getByRole("button", { name: "Resend code" }).click()
    const second = (await codes.next()).value
    await page.locator(".phx-connected").waitFor()
    await page.getByLabel("One-time code").fill(second.replace("-", ""))
    await expect(page.getByLabel("One-time code")).toHaveValue(second)
    await page.getByRole("button", { name: "Sign in", exact: true }).click()
    await expect(page).toHaveURL(/\/people\/profile$/)
    await expect(page.getByRole("heading", { name: "Profile" })).toBeVisible()
    await expect(page.getByText("Welcome, Browser Person.")).toBeVisible()
    const cookie = (await context.cookies()).find(cookie => cookie.name === "_zaq_key")
    expect(cookie.httpOnly).toBe(true)
    expect(cookie.sameSite).toBe("Lax")
    expect(cookie.expires).toBe(-1)
    expect(await page.evaluate(() => document.cookie)).not.toContain("_zaq_key")
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await expect(page.getByRole("navigation", { name: "People" })).toBeVisible()
    if (width === 1280) {
      await boLogin()
      await page.goto(`${baseURL}/people/profile`)
      await expect(page.getByText("Welcome, Browser Person.")).toBeVisible()
    }
    await page.getByRole("button", { name: "Sign out" }).click()
    await expect(page).toHaveURL(/\/people\/login$/)
    await page.goto(`${baseURL}/people/profile`)
    await expect(page).toHaveURL(/\/people\/login$/)
    await page.goto(`${baseURL}/bo/profile`)
    await expect(page).toHaveURL(/\/bo\/profile$/)
    await expect(page.getByRole("heading", { name: "My Profile", exact: true })).toBeVisible()
    await page.goto(`${baseURL}/people/login`)
    await page.getByLabel("Email address").fill(email)
    await page.getByRole("button", { name: "Send sign-in code" }).click()
    const third = (await codes.next()).value
    await page.getByLabel("One-time code").fill(third)
    await page.getByRole("button", { name: "Sign in", exact: true }).click()
    await expect(page).toHaveURL(/\/people\/profile$/)
    const csrf = await page.locator("meta[name=csrf-token]").getAttribute("content")
    const logout = await page.request.post(`${baseURL}/bo/session`, {
      form: { _method: "delete", _csrf_token: csrf }, maxRedirects: 0
    })
    expect(logout.status()).toBe(302)
    await page.goto(`${baseURL}/people/profile`)
    await expect(page.getByText("Welcome, Browser Person.")).toBeVisible()
    await page.getByRole("button", { name: "Sign out" }).click()
    await page.goto(`${baseURL}/bo/profile`)
    await expect(page).toHaveURL(/\/bo\/login$/)
    expect(errors).toEqual([])
    console.log(`${engine}: ${width}px passed (OTP recovery/resend and both logout directions)`)
    await context.close()
    }
  } finally {
    await browser.close()
    process.stdin.destroy()
  }
}

main().catch(error => { console.error(error); process.exit(1) })
