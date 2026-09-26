const { test, expect } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  waitForLiveViewSettled,
} = require("../support/bo")

test.describe("Multilingual ingestion details", () => {
  test.beforeEach(async ({ page }) => {
    await resetE2EState(page.request)
    await loginToBackOffice(page)
  })

  test("shows detected languages, ParadeDB default indexing, extracted Markdown and a repaired summary", async ({ page }) => {
    const name = `multilingual-${Date.now()}.md`
    const content = "# Maintenance instructions\n\n" +
      "The engineering team inspects the equipment.\n\n" +
      "# Instructions de maintenance\n\nL'équipe inspecte les équipements.\n\n" +
      "# تعليمات الصيانة\n\nيراجع الفريق المعدات كل صباح."

    await gotoBackOfficeLive(page, "/bo/ingestion")
    await page.locator("#add-raw-md-button").click()
    await expect(page.locator("#add-raw-modal")).toBeVisible()
    await page.locator("#raw-filename-input").fill(name.replace(/\.md$/, ""))
    await page.locator("#raw-content-input").fill(content)
    await page.locator("#save-raw-file-button").click()
    await expect(page.locator("#add-raw-modal")).toBeHidden()

    const row = page.locator("#ingestion-file-list tr").filter({
      has: page.locator(`button[phx-click="open_preview"][title="${name}"]`),
    })
    await expect(row).toBeVisible()
    await row.getByRole("checkbox").check()
    await expect(page.locator("#ingest-selected-button")).toContainText("(1)")
    await page.locator("#ingest-selected-button").click()
    await expect(row).toContainText("ingested", { timeout: 60_000 })

    async function setSummary(phase) {
      const response = await page.request.post("/e2e/ingestion/multilingual_summary", {
        data: { content, phase },
      })
      expect(response.ok()).toBeTruthy()
      await gotoBackOfficeLive(page, "/bo/ingestion")
      await waitForLiveViewSettled(page)
    }

    async function openDetails() {
      const badge = page.locator("#ingestion-file-list tr").filter({
        has: page.locator(`button[phx-click="open_preview"][title="${name}"]`),
      })
      await badge.getByRole("button", { name: `View ingestion details for ${name}` }).click()
      const modal = page.locator("#ingestion-details-modal")
      await expect(modal).toBeVisible()
      return modal
    }

    await setSummary("partial")
    const rowAfterPartial = page.locator("#ingestion-file-list tr").filter({
      has: page.locator(`button[phx-click="open_preview"][title="${name}"]`),
    })
    await expect(rowAfterPartial).not.toContainText("default analyzer")

    let modal = await openDetails()
    await expect(modal.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "2")
    await expect(modal).toContainText("0 language-specific")
    await expect(modal).toContainText("2 default analyzer")
    await expect(modal).toContainText("1 unindexed")
    await expect(modal.locator(".zaq-ingestion-progress__language")).toHaveText([
      "Arabic", "English", "French",
    ])
    await modal.locator(".zaq-ingestion-progress__errors summary").click()
    await expect(modal).toContainText("Chunk 3: Embedding unavailable")
    await expect(modal.locator(".md-content h1").first()).toContainText("Maintenance instructions")
    await expect(modal.locator(".md-content h1").nth(1)).toContainText("Instructions de maintenance")
    await expect(modal.locator(".md-content")).toContainText("يراجع الفريق المعدات")

    await page.keyboard.press("Escape")
    await expect(modal).toBeHidden()

    await setSummary("recovered")
    modal = await openDetails()
    await expect(modal.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "3")
    await expect(modal).toContainText("3 default analyzer")
    await expect(modal).toContainText("0 unindexed")
    await expect(modal.locator(".zaq-ingestion-progress__errors")).toHaveCount(0)
    await modal.getByRole("button", { name: "Close dialog" }).click()
    await expect(modal).toBeHidden()
  })
})
