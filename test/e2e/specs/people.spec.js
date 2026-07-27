const { test, expect, request: apiRequest } = require("@playwright/test")
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  pickSearchableSelect,
  resetE2EState,
  waitForServerRoundTrip,
} = require("../support/bo")

const PEOPLE_PATH = "/bo/people"

// Mirrors phx-debounce on the people filter inputs (people_live.ex).
const FILTER_DEBOUNCE_MS = 300

const SEL = {
  tabPeople: '[phx-value-tab="people"]',
  tabTeams: '[phx-value-tab="teams"]',

  newPersonButton: "#new-person-button",
  savePersonButton: "#save-person-button",
  newTeamButton: "#new-team-button",
  saveTeamButton: "#save-team-button",
  teamNameInput: 'input[name="team[name]"]',
  addChannelButton: "#add-channel-button",
  saveChannelButton: "#save-channel-button",

  modalOverlay: "#people-modal-overlay",

  // Person form fields
  fullNameInput: 'input[name="person[full_name]"]',
  emailInput: 'input[name="person[email]"]',
  phoneInput: 'input[name="person[phone]"]',
  roleInput: 'input[name="person[role]"]',

  // Channel form fields
  platformSelect: 'select[name="channel[platform]"]',
  channelIdentifierInput: 'input[name="channel[channel_identifier]"]',

  // Filters
  filterName: 'input[name="filter_name"]',
  filterEmail: 'input[name="filter_email"]',
  filterPhone: 'input[name="filter_phone"]',
  filterComplete: 'select[name="filter_complete"]',

  // Pagination
  paginationInfo: '[data-testid="simple-pagination-range"]',
  nextPage: 'button:has-text("Next →")',
  prevPage: 'button:has-text("← Prev")',

  // Merge
  mergeSearchInput: 'input[name="merge_search"]',
  confirmMergeButton: '[phx-click="confirm_merge"]',
}

test.describe("People", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext()
    await resetE2EState(req)
    await req.dispose()
  })

  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page)
    await gotoBackOfficeLive(page, PEOPLE_PATH)
  })

  // ── Navigation ────────────────────────────────────────────────────────────

  test("default tab is People", async ({ page }) => {
    await expect(page.locator(SEL.tabPeople)).toBeVisible()
    await expect(page.locator(SEL.newPersonButton)).toBeVisible()
  })

  test("master-detail layout shell is present on people page", async ({ page }) => {
    await expect(page.locator('[data-testid="bo-master-detail-layout"]')).toBeVisible()
    await expect(page.locator("#people-master-pane")).toBeVisible()
  })

  test("switching to Teams tab shows New Team button", async ({ page }) => {
    await page.locator(SEL.tabTeams).click()
    await expect(page.locator("#new-team-button")).toBeVisible()
    await expect(page.locator(SEL.newPersonButton)).not.toBeVisible()
  })

  // ── Create person ─────────────────────────────────────────────────────────

  test("creates a new complete person and shows them in the list", async ({ page }) => {
    const ts = Date.now()
    const name = `E2E Person ${ts}`

    await page.locator(SEL.newPersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).toBeVisible()

    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.emailInput).fill(`${ts}@example.com`)
    await page.locator(SEL.phoneInput).fill("+1 555 000 0001")

    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)
    await expect(page.getByText(name)).toBeVisible()
  })

  test("creates an incomplete person (no phone) and shows incomplete badge", async ({ page }) => {
    const ts = Date.now()
    const name = `E2E Incomplete ${ts}`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.emailInput).fill(`incomplete-${ts}@example.com`)
    // No phone → stays incomplete

    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)

    // Select the person to verify incomplete badge in detail panel
    await page.getByText(name).click()
    await expect(page.locator('[phx-click="deselect_person"]')).toBeVisible()
    // Incomplete badge appears in status cell
    await expect(page.locator(".bg-amber-100", { hasText: "incomplete" }).first()).toBeVisible()
  })

  // ── Merge flow ────────────────────────────────────────────────────────────

  test("merge modal opens from detail panel Merge button", async ({ page }) => {
    const ts = Date.now()
    const nameA = `E2E MergeA ${ts}`
    const nameB = `E2E MergeB ${ts}`

    // Create person A
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameA)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Create person B
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameB)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)

    // Select person A → open merge modal
    await selectPerson(page, nameA)
    await page.locator('[phx-click="open_merge_modal"]').first().click()

    await expect(page.locator(SEL.modalOverlay)).toBeVisible()
    await expect(page.getByText("Merge Persons")).toBeVisible()
    await expect(page.getByText("Survivor (kept)", { exact: false })).toBeVisible()
    await expect(page.locator(SEL.mergeSearchInput)).toBeVisible()
  })

  test("merge: search finds the loser, confirm merges and deletes the loser", async ({ page }) => {
    const ts = Date.now()
    const nameSurvivor = `E2E Survivor ${ts}`
    const nameLoser = `E2E Loser ${ts}`

    // Create survivor
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameSurvivor)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Create loser
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameLoser)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Filter to just these two people so they're visible regardless of page
    await filterByName(page, `${ts}`)
    await expect(page.getByText(nameSurvivor)).toBeVisible()

    // Select survivor → open merge modal
    await selectPerson(page, nameSurvivor)
    await page.locator('[phx-click="open_merge_modal"]').first().click()
    await expect(page.locator(SEL.modalOverlay)).toBeVisible()

    // Search for loser
    await page.locator(SEL.mergeSearchInput).fill(`E2E Loser ${ts}`)
    // Wait for candidate to appear and click it
    await page.locator('[phx-click="select_merge_loser"]').first().click()

    // Confirm merge button should appear
    await expect(page.locator(SEL.confirmMergeButton)).toBeVisible()
    await page.locator(SEL.confirmMergeButton).click()

    // Modal closes, success flash
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()
    await expect(page.getByText("Persons merged successfully")).toBeVisible()

    // Loser no longer in people list
    await expect(page.getByText(nameLoser)).not.toBeVisible()
  })

  // ── Channel management ────────────────────────────────────────────────────

  test("platform dropdown includes telegram and discord", async ({ page }) => {
    // Create a person first so the detail panel and Add Channel button are accessible
    const name = `E2E ChanPlatform ${Date.now()}`
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, name)
    const personRow = page.getByText(name).first()
    await expect(personRow).toBeVisible()
    await selectPerson(page, name)
    await page.locator(SEL.addChannelButton).click()
    await expect(page.locator(SEL.modalOverlay)).toBeVisible()

    const options = await page.locator(`${SEL.platformSelect} option`).allTextContents()
    expect(options).toContain("telegram")
    expect(options).toContain("discord")
  })

  // ── Filtering ─────────────────────────────────────────────────────────────

  test("filter by name narrows results", async ({ page }) => {
    const ts = Date.now()
    const nameA = `E2E FilterA ${ts}`
    const nameB = `E2E FilterB ${ts}`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameA)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(nameB)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, nameA)
    await expect(page.getByText(nameA)).toBeVisible()
    await expect(page.getByText(nameB)).not.toBeVisible()
  })

  test("filter by email narrows results", async ({ page }) => {
    const ts = Date.now()
    const name = `E2E FilterEmail ${ts}`
    const email = `filter-email-${ts}@example.com`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.emailInput).fill(email)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await page.locator(SEL.filterEmail).fill(`filter-email-${ts}`)
    await expect(page.getByText(name)).toBeVisible()
  })

  test("filter by complete status shows only complete people", async ({ page }) => {
    const ts = Date.now()
    const completeName = `E2E Complete ${ts}`
    const incompleteName = `E2E Incomplete ${ts}`

    // Complete requires full_name + email + phone
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(completeName)
    await page.locator(SEL.emailInput).fill(`complete-${ts}@example.com`)
    await page.locator(SEL.phoneInput).fill("+1 555 000 0099")
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Incomplete person (no phone)
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(incompleteName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)
    await page.locator(SEL.filterComplete).selectOption("complete")
    await expect(page.getByText(completeName)).toBeVisible()
    await expect(page.getByText(incompleteName)).not.toBeVisible()
  })

  test("filter by incomplete status shows only incomplete people", async ({ page }) => {
    const ts = Date.now()
    const completeName = `E2E CmpFull ${ts}`
    const incompleteName = `E2E IncFull ${ts}`

    // Complete requires full_name + email + phone
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(completeName)
    await page.locator(SEL.emailInput).fill(`cmpfull-${ts}@example.com`)
    await page.locator(SEL.phoneInput).fill("+1 555 000 0088")
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(incompleteName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)
    await page.locator(SEL.filterComplete).selectOption("incomplete")
    await expect(page.getByText(incompleteName)).toBeVisible()
    await expect(page.getByText(completeName)).not.toBeVisible()
  })

  test("clearing filters restores full list", async ({ page }) => {
    const ts = Date.now()
    const name = `E2E ClearFilter ${ts}`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, "zzz-no-match")
    await expect(page.getByText(name)).not.toBeVisible()

    // Clear no-match filter and re-filter by unique ts — person must be visible again
    await filterByName(page, `${ts}`)
    await expect(page.getByText(name)).toBeVisible()
  })

  // ── Pagination ────────────────────────────────────────────────────────────

  test("pagination info shows range and total when people exist", async ({ page }) => {
    const name = `E2E PagInfo ${Date.now()}`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // e.g. "1–5 of 5"
    await expect(page.locator(SEL.paginationInfo).filter({ hasText: "of" }).first()).toBeVisible()
  })

  test("next/prev buttons absent when filtered results fit on one page", async ({ page }) => {
    const ts = Date.now()
    const name = `E2E PagSingle ${ts}`

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(name)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Filter to exactly this one person
    await filterByName(page, `${ts}`)
    await expect(page.getByText(name)).toBeVisible()

    await expect(page.locator(SEL.nextPage)).not.toBeVisible()
    await expect(page.locator(SEL.prevPage)).not.toBeVisible()
  })

  // ── Teams ─────────────────────────────────────────────────────────────────

  test("team created in Teams tab can be assigned to person and used as filter", async ({ page }) => {
    const ts = Date.now()
    const teamName = `Team ${ts}`
    const personName = `E2E TeamFilter ${ts}`

    // Create team from Teams tab
    await page.locator(SEL.tabTeams).click()
    await page.locator(SEL.newTeamButton).click()
    await page.locator(SEL.teamNameInput).fill(teamName)
    await page.locator(SEL.saveTeamButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()
    await expect(page.getByText(teamName)).toBeVisible()

    // Create person from People tab
    await page.locator(SEL.tabPeople).click()
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(personName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Filter to person and select them
    await filterByName(page, `${ts}`)
    await selectPerson(page, personName)

    // Assign team from detail panel
    await pickSearchableSelect(page, 'form[phx-change="assign_team_select"]', teamName)
    await expect(teamBadge(page, teamName)).toBeVisible()

    // Filter by team — person should appear in the list
    await filterByName(page, "")
    await pickSearchableSelect(page, '#filter-team-select', teamName)
    await expect(page.getByText(personName).first()).toBeVisible()
  })

  test("team can be created inline from person detail panel", async ({ page }) => {
    const ts = Date.now()
    const teamName = `Inline Team ${ts}`
    const personName = `E2E InlineTeam ${ts}`

    // Create person and select them
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(personName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await filterByName(page, `${ts}`)
    await selectPerson(page, personName)

    // Open the team assign select, type a new team name, hit Create
    await createAndAssignTeam(page, teamName)

    // Team badge appears on the person
    await expect(teamBadge(page, teamName)).toBeVisible()
  })

  test("merging persons unions their teams onto the survivor", async ({ page }) => {
    const ts = Date.now()
    const survivorName = `E2E TeamSurvivor ${ts}`
    const loserName = `E2E TeamLoser ${ts}`
    const teamA = `TeamA ${ts}`
    const teamB = `TeamB ${ts}`

    // Create both people
    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(survivorName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    await page.locator(SEL.newPersonButton).click()
    await page.locator(SEL.fullNameInput).fill(loserName)
    await page.locator(SEL.savePersonButton).click()
    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()

    // Assign teamA to survivor
    await filterByName(page, `${ts}`)
    await selectPerson(page, survivorName)
    await createAndAssignTeam(page, teamA)
    await expect(teamBadge(page, teamA)).toBeVisible()

    // Assign teamB to loser
    await selectPerson(page, loserName)
    await createAndAssignTeam(page, teamB)
    await expect(teamBadge(page, teamB)).toBeVisible()

    // Merge loser into survivor
    await selectPerson(page, survivorName)
    await page.locator('[phx-click="open_merge_modal"]').first().click()
    await expect(page.locator(SEL.modalOverlay)).toBeVisible()

    await page.locator(SEL.mergeSearchInput).fill(loserName)
    await page.locator('[phx-click="select_merge_loser"]').first().click()
    await page.locator(SEL.confirmMergeButton).click()

    await expect(page.locator(SEL.modalOverlay)).not.toBeVisible()
    await expect(page.getByText("Persons merged successfully")).toBeVisible()

    // Survivor should now carry both teams (detail panel already open)
    await selectPerson(page, survivorName)
    await expect(teamBadge(page, teamA)).toBeVisible()
    await expect(teamBadge(page, teamB)).toBeVisible()
  })
})

// ── Helpers ───────────────────────────────────────────────────────────────────

// The filter inputs carry phx-debounce="300", so the LiveView patch lands up to
// ~300ms after .fill() has already resolved. Acting on the list inside that
// window silently loses the interaction: morphdom is re-keying #people-table's
// tbody, and LiveView's delegated handler resolves the click target after the
// row node was detached, so the phx-click is dropped with no error. Outlast the
// debounce, then wait for the resulting round trip to finish patching the DOM.
async function filterByName(page, term) {
  await page.locator(SEL.filterName).fill(`${term}`)
  await page.waitForTimeout(FILTER_DEBOUNCE_MS + 50)
  await waitForServerRoundTrip(page)
}

async function selectPerson(page, name) {
  const row = page.locator("#people-table tbody tr", { hasText: name }).first()
  await expect(row).toBeVisible()
  await row.click()

  const detail = page.locator("#people-detail-pane")
  await expect(detail).toBeVisible()
  await expect(detail.locator("h3")).toHaveText(name)
}

async function createAndAssignTeam(page, teamName) {
  const containerSel = 'form[phx-change="assign_team_select"]'
  const trigger = page.locator(`${containerSel} [data-select-trigger]`)
  const panel = page.locator(`${containerSel} [data-select-panel]`)
  const search = page.locator(`${containerSel} [data-select-search]`)
  const create = page.locator(`${containerSel} [data-select-create]`)

  await expect(trigger).toBeVisible()

  let opened = false
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await trigger.click({ force: true })
    try {
      await expect(panel).toBeVisible({ timeout: 600 })
      await expect(search).toBeVisible({ timeout: 600 })
      opened = true
      break
    } catch (_error) {
      await page.waitForTimeout(120)
    }
  }

  expect(opened).toBeTruthy()
  await search.fill(teamName)
  await expect(create).toBeVisible()
  await create.click()
}

function teamBadge(page, teamName) {
  return page.locator('[data-testid^="person-team-badge-"]').filter({ hasText: teamName })
}
