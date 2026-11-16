const { test } = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
const { chromium, firefox, webkit } = require('@playwright/test')
const { gotoBackOfficeLive } = require('./bo')

for (const [name, browserType] of Object.entries({ chromium, firefox, webkit })) {
  test(`${name}: full-page navigation cancels the outgoing LiveView recovery reload`, { timeout: 20_000 }, async () => {
    const browser = await browserType.launch()
    const page = await browser.newPage()
    let originalRequests = 0
    let recoveryReloads = 0

    try {
      await page.exposeFunction('recordRecoveryReload', () => { recoveryReloads++ })
      await page.route('http://navigation.test/**', async route => {
        if (new URL(route.request().url()).pathname === '/original') {
          originalRequests++
        }
        await route.fulfill({
          contentType: 'text/html',
          body: '<div data-phx-main class="phx-connected">Ready</div><script>window.liveSocket = {isConnected: () => true}</script>',
        })
      })
      await page.goto('http://navigation.test/original')
      await page.addScriptTag({ path: path.resolve(__dirname, '../../../deps/phoenix/priv/static/phoenix.js') })
      await page.addScriptTag({ path: path.resolve(__dirname, '../../../deps/phoenix_live_view/priv/static/phoenix_live_view.js') })
      const now = new Date('2026-01-01T00:00:00Z')
      await page.clock.install({ time: now })
      await page.clock.pauseAt(now)
      await page.evaluate(() => {
        window.liveSocket = new window.LiveView.LiveSocket('/live', window.Phoenix.Socket, {
          reloadJitterMin: 1000,
          reloadJitterMax: 1000,
        })
        // Use LiveView's real recovery timer rather than mocking disconnect.
        window.liveSocket.reloadWithJitter({
          isDestroyed: () => false,
          isConnected: () => false,
          destroy: () => window.recordRecoveryReload(),
        })
      })

      const goto = page.goto.bind(page)
      page.goto = async (...args) => {
        // Advance the outgoing document's clock at the navigation boundary.
        await page.clock.runFor(1001)
        return goto(...args)
      }
      await gotoBackOfficeLive(page, 'http://navigation.test/destination')
      assert.equal(recoveryReloads, 0, 'the outgoing recovery timer must be cancelled')
      assert.equal(originalRequests, 1, 'the outgoing document must not reload')
      assert.equal(page.url(), 'http://navigation.test/destination')
      assert.equal(await page.locator('[data-phx-main]').textContent(), 'Ready')
    } finally {
      await browser.close()
    }
  })
}

test('chromium: navigation works without LiveView and preserves navigation errors', { timeout: 20_000 }, async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  try {
    await page.route('http://navigation.test/plain', route => route.fulfill({ body: 'Plain page' }))
    await gotoBackOfficeLive(page, 'http://navigation.test/plain', { ensureConnected: false })
    assert.equal(await page.locator('body').textContent(), 'Plain page')
    await page.route('http://navigation.test/failure', route => route.abort('failed'))
    await assert.rejects(gotoBackOfficeLive(page, 'http://navigation.test/failure', { ensureConnected: false }))
  } finally {
    await browser.close()
  }
})
