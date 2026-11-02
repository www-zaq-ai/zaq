const { test } = require('node:test')
const assert = require('node:assert/strict')
const { chromium } = require('@playwright/test')
const { expectFlashDuringAction } = require('./bo')

test('retains displayed flash evidence after dismissal, rejects wrong or absent flashes, and handles navigation', async () => {
  const browser = await chromium.launch()
  const page = await browser.newPage()
  const show = text => page.evaluate(text => {
    const banner = document.createElement('div')
    banner.id = 'flash-info'
    banner.innerHTML = '<span class="zaq-feedback-body"></span>'
    banner.firstChild.textContent = text
    document.body.append(banner)
  }, text)
  try {
    await page.setContent('<body></body>')
    await page.clock.install()
    await expectFlashDuringAction(page, 'Saved.', async () => {
      await show('Saved.')
      await page.evaluate(() => setTimeout(() => document.querySelector('#flash-info').remove(), 5000))
      await page.clock.runFor(6000)
    })
    assert.equal(await page.locator('#flash-info').count(), 0)
    await assert.rejects(expectFlashDuringAction(page, 'Saved.', async () => {}, { timeout: 200 }))
    await assert.rejects(expectFlashDuringAction(page, 'Saved.', () => show('Wrong.'), { timeout: 200 }))
    await page.evaluate(() => document.querySelector('#flash-info').remove())
    await assert.rejects(expectFlashDuringAction(page, 'Saved.', () => page.evaluate(() => {
      document.body.insertAdjacentHTML('beforeend', '<div id="flash-info" hidden>Saved.</div>')
    }), { timeout: 200 }))
    await page.evaluate(() => document.querySelector('#flash-info').remove())
    await show('Saved.')
    await assert.rejects(expectFlashDuringAction(page, 'Saved.', async () => {}, { timeout: 200 }))
    await expectFlashDuringAction(page, 'Saved.', () => page.evaluate(() => {
      document.querySelector('#flash-info .zaq-feedback-body').textContent = 'Saved. Runtime restarted.'
    }))
    await assert.rejects(expectFlashDuringAction(page, 'Saved.', () => page.evaluate(() => {
      document.querySelector('#flash-info .zaq-feedback-body').textContent = 'Saved. Another suffix.'
    }), { timeout: 200, exact: true }))
    await page.evaluate(() => document.querySelector('#flash-info').remove())
    await page.route('http://flash.test/**', route => route.fulfill({ contentType: 'text/html', body: '<div id="flash-info"><span class="zaq-feedback-body">Navigated.</span></div>' }))
    await expectFlashDuringAction(page, 'Navigated.', () => page.goto('http://flash.test/'))
  } finally {
    await browser.close()
  }
})
