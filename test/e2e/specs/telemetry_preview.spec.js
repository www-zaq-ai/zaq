const { test, expect } = require("@playwright/test")
const { gotoBackOfficeLive, loginToBackOffice } = require("../support/bo")

test.describe("Telemetry Preview", () => {
  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page)
  })

  test("renders interactive charts with correct gauge orientation", async ({ page }, testInfo) => {
    await gotoBackOfficeLive(page, "/bo/dashboard/telemetry-preview")

    await expect(page.locator("#telemetry-preview-page")).toBeVisible()
    await expect(page.locator("#telemetry-component-gallery")).toBeVisible()
    await expect(page.locator("#telemetry-composed-dashboard")).toBeVisible()

    const tooltip = page.locator("#bo-chart-tooltip")

    const linePoint = page.locator("#gallery-time-series-chart [data-tip-value]").first()
    await linePoint.dispatchEvent("mouseover")
    await linePoint.dispatchEvent("mousemove")
    await expect(tooltip.locator("[data-tip-label]")).toContainText(/T\d+/)
    await expect(tooltip.locator("[data-tip-value]")).not.toHaveText("--")

    const donutArc = page.locator("#gallery-donut-chart svg [data-tip-value]").first()
    await donutArc.dispatchEvent("mouseover")
    await donutArc.dispatchEvent("mousemove")
    await expect(tooltip.locator("[data-tip-value]")).toContainText("%")

    const radarPoint = page.locator("#gallery-radar-chart svg [data-tip-value]").first()
    const radarLabel = await radarPoint.getAttribute("data-tip-label")
    const radarColor = await radarPoint.getAttribute("data-tip-color")

    await radarPoint.dispatchEvent("mouseover")
    await radarPoint.dispatchEvent("mousemove")
    await expect(tooltip.locator("[data-tip-label]")).toContainText(radarLabel)

    const radarLegendRow = page.locator(`#gallery-radar-chart [data-radar-label="${radarLabel}"]`)
    await expect(radarLegendRow).toHaveAttribute("data-radar-color", radarColor)

    const gaugeSection = page.locator("#gallery-gauge-chart")
    await expect(gaugeSection).toBeVisible()

    const pointerX = Number(await gaugeSection.getAttribute("data-pointer-x"))
    const pointerY = Number(await gaugeSection.getAttribute("data-pointer-y"))
    const gaugeRatio = Number(await gaugeSection.getAttribute("data-gauge-ratio"))

    expect(gaugeRatio).toBeGreaterThan(0.6)
    expect(pointerX).toBeGreaterThan(110)
    expect(pointerY).toBeLessThan(110)

    await page.locator("#range-90d").click()
    await expect(page.locator("#selected-range")).toHaveText("90d")

    await page.locator("#benchmark-toggle").click()
    await expect(page.locator("#benchmark-state")).toHaveText("on")

    await page.locator("#segment-industry").click()
    await expect(page.locator("#selected-segment")).toHaveText("industry")

    await page.locator("#feedback-all").click()
    await expect(page.locator("#selected-feedback-scope")).toHaveText("all")

    await page.screenshot({
      path: testInfo.outputPath("telemetry-preview-full.png"),
      fullPage: true,
    })

    await gaugeSection.screenshot({
      path: testInfo.outputPath("telemetry-preview-gauge.png"),
    })
  })
})
