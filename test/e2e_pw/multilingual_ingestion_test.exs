defmodule Zaq.E2EPw.MultilingualIngestionTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Multilingual ingestion details
  setup %{page: page} do
    reset_e2e_state(Page.request(page))
    login_to_back_office(page)
    :ok
  end

  defp file_row(page, name) do
    page
    |> Page.locator("#ingestion-file-list tr")
    |> Locator.filter(
      has: Page.locator(page, ~s|button[phx-click="open_preview"][title="#{name}"]|)
    )
  end

  test "shows detected languages, ParadeDB default indexing, extracted Markdown and a repaired summary",
       %{page: page} do
    name = "multilingual-#{System.system_time(:millisecond)}.md"

    content =
      "# Maintenance instructions\n\n" <>
        "The engineering team inspects the equipment.\n\n" <>
        "# Instructions de maintenance\n\nL'équipe inspecte les équipements.\n\n" <>
        "# تعليمات الصيانة\n\nيراجع الفريق المعدات كل صباح."

    goto_back_office_live(page, "/bo/ingestion")
    page |> Page.locator("#add-raw-md-button") |> Locator.click!()
    page |> Page.locator("#add-raw-modal") |> Expect.to_be_visible!()

    page
    |> Page.locator("#raw-filename-input")
    |> Locator.fill!(String.replace(name, ~r/\.md$/, ""))

    page |> Page.locator("#raw-content-input") |> Locator.fill!(content)
    page |> Page.locator("#save-raw-file-button") |> Locator.click!()
    page |> Page.locator("#add-raw-modal") |> Expect.to_be_hidden!()

    row = file_row(page, name)
    Expect.to_be_visible!(row)
    row |> Locator.get_by_role(:checkbox) |> Locator.check!()
    page |> Page.locator("#ingest-selected-button") |> Expect.to_contain_text!("(1)")
    page |> Page.locator("#ingest-selected-button") |> Locator.click!()
    Expect.to_contain_text!(row, "ingested", timeout: 60_000)

    set_summary = fn phase ->
      response =
        APIRequestContext.post!(
          Page.request(page),
          normalize_base_url() <> "/e2e/ingestion/multilingual_summary",
          data: %{content: content, phase: phase}
        )

      assert APIResponse.ok(response)
      goto_back_office_live(page, "/bo/ingestion")
      wait_for_live_view_settled(page)
    end

    open_details = fn ->
      badge = file_row(page, name)

      badge
      |> Locator.get_by_role(:button, name: "View ingestion details for #{name}")
      |> Locator.click!()

      modal = Page.locator(page, "#ingestion-details-modal")
      Expect.to_be_visible!(modal)
      modal
    end

    set_summary.("partial")
    row_after_partial = file_row(page, name)
    row_after_partial |> Expect.not_() |> Expect.to_contain_text!("default analyzer")

    modal = open_details.()
    modal |> Locator.get_by_role(:progressbar) |> Expect.to_have_attribute!("aria-valuenow", "2")
    Expect.to_contain_text!(modal, "0 language-specific")
    Expect.to_contain_text!(modal, "2 default analyzer")
    Expect.to_contain_text!(modal, "1 unindexed")

    modal
    |> Locator.locator(".zaq-ingestion-progress__language")
    |> Expect.to_have_text!(["Arabic", "English", "French"])

    modal |> Locator.locator(".zaq-ingestion-progress__errors summary") |> Locator.click!()
    Expect.to_contain_text!(modal, "Chunk 3: Embedding unavailable")

    modal
    |> Locator.locator(".md-content h1")
    |> Locator.first()
    |> Expect.to_contain_text!("Maintenance instructions")

    modal
    |> Locator.locator(".md-content h1")
    |> Locator.nth(1)
    |> Expect.to_contain_text!("Instructions de maintenance")

    modal |> Locator.locator(".md-content") |> Expect.to_contain_text!("يراجع الفريق المعدات")

    page |> Page.keyboard() |> Playwright.Keyboard.press!("Escape")
    Expect.to_be_hidden!(modal)

    set_summary.("recovered")
    modal = open_details.()
    modal |> Locator.get_by_role(:progressbar) |> Expect.to_have_attribute!("aria-valuenow", "3")
    Expect.to_contain_text!(modal, "3 default analyzer")
    Expect.to_contain_text!(modal, "0 unindexed")
    modal |> Locator.locator(".zaq-ingestion-progress__errors") |> Expect.to_have_count!(0)
    modal |> Locator.get_by_role(:button, name: "Close dialog") |> Locator.click!()
    Expect.to_be_hidden!(modal)
  end
end
