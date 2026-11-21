defmodule Zaq.E2EPw.KnowledgeOpsLeadTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Knowledge Ops Lead journeys
  setup_all %{browser: browser} do
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    reset_e2e_state(request)
    APIRequestContext.dispose!(request)
    {:ok, agent_store} = Agent.start(fn -> nil end)
    on_exit(fn -> Agent.stop(agent_store) end)
    %{agent_store: agent_store}
  end

  setup %{page: page, agent_store: store} do
    login_to_back_office(page)

    agent =
      Agent.get_and_update(store, fn
        nil ->
          agent = create_e2e_answering_agent(page)
          {agent, agent}

        agent ->
          {agent, agent}
      end)

    %{agent: agent}
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.system_time(:millisecond)}"

  defp preview_path(relative_path) do
    encoded =
      relative_path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))

    "/bo/preview/#{encoded}"
  end

  defp add_raw_markdown(page, file_name_without_ext, content) do
    page |> Page.locator("#add-raw-md-button") |> Locator.click!()
    page |> Page.locator("#add-raw-modal") |> Expect.to_be_visible!()

    page |> Page.locator("#raw-filename-input") |> Locator.fill!(file_name_without_ext)
    page |> Page.locator("#raw-content-input") |> Locator.fill!(content)
    page |> Page.locator("#save-raw-file-button") |> Locator.click!()

    page |> Page.locator("#add-raw-modal") |> Expect.to_be_hidden!()
  end

  defp file_row(page, file_name) do
    page
    |> Page.locator("tr")
    |> Locator.filter(
      has: Page.locator(page, ~s|button[phx-click="open_preview"][title="#{file_name}"]|)
    )
    |> Locator.first()
  end

  defp select_file_row(page, file_name) do
    row = file_row(page, file_name)
    Expect.to_be_visible!(row)

    checkbox = row |> Locator.locator(~s|input[type="checkbox"]|) |> Locator.first()
    Locator.check!(checkbox)
    Expect.to_be_checked!(checkbox)
  end

  defp ingest_selected_async(page, file_name) do
    page |> Page.locator("#ingest-selected-button") |> Expect.to_contain_text!("(1)")
    page |> Page.locator("#ingest-selected-button") |> Locator.click!()
    page |> Page.locator("#ingest-selected-button") |> Expect.to_contain_text!("(0)")
    file_row(page, file_name) |> Expect.to_contain_text!("ingested", timeout: 30_000)
  end

  defp ask_question(page, question, agent) do
    goto_back_office_live(page, "/bo/chat")
    page |> Page.locator("#chat-form") |> Expect.to_be_visible!()
    page |> Page.locator("#new-chat-button") |> Locator.click!()

    # Wait for the new_chat event to settle server-side before typing the next question.
    wait_for_live_view_settled(page)

    select_e2e_chat_agent(page, agent)

    page |> Page.locator("#chat-input") |> Locator.fill!(question)
    page |> Page.locator("#chat-form button[type='submit']") |> Locator.click!()
  end

  defp open_first_source_preview_modal(page) do
    source_chip = page |> Page.locator(~s|[data-testid="source-chip"]|) |> Locator.first()
    Expect.to_be_visible!(source_chip)
    Expect.to_be_enabled!(source_chip)
    Locator.click!(source_chip)

    modal = Page.locator(page, "#file-preview-modal")
    Expect.to_be_visible!(modal)
    Expect.to_have_url!(page, ~r{/bo/chat})
    modal
  end

  defp folder_button(page, folder_name) do
    page
    |> Page.locator(~s|table button[phx-click="navigate"]|)
    |> Locator.filter(has_text: folder_name)
    |> Locator.first()
  end

  test "Journey 1: ingest new knowledge and confirm it is queryable", %{page: page, agent: agent} do
    file_base = unique_id("e2e-journey-one")
    file_name = "#{file_base}.md"
    query_token = "#{String.replace(file_base, "-", "_")}_signal"

    goto_back_office_live(page, "/bo/ingestion")

    add_raw_markdown(
      page,
      file_base,
      "# Journey One Source\n\nThis document contains #{query_token} and should be retrieved first."
    )

    select_file_row(page, file_name)
    ingest_selected_async(page, file_name)

    goto_back_office_live(page, "/bo/ingestion")

    Page.goto!(page, preview_path(file_name))
    page |> Page.locator("body") |> Expect.to_contain_text!(query_token)

    raw_page =
      Page.expect_popup!(page, fn ->
        page |> Page.get_by_role(:link, name: "Raw") |> Locator.click!()
      end)

    Page.wait_for_load_state!(raw_page, :domcontentloaded)
    raw_page |> Page.locator("body") |> Expect.to_contain_text!(query_token)
    Page.close!(raw_page)

    ask_question(page, "What do you know about #{query_token}?", agent)

    page
    |> Page.locator("#chat-messages")
    |> Expect.to_contain_text!("Baseline response generated from the default prompt template.",
      timeout: 30_000
    )

    page
    |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|)
    |> Locator.first()
    |> Expect.to_be_visible!(timeout: 30_000)

    modal = open_first_source_preview_modal(page)
    Expect.to_contain_text!(modal, query_token)
  end

  test "Journey 2: maintain hierarchy and stale-document hygiene", %{page: page, request: request} do
    folder_name = unique_id("e2e-folder")
    file_base = unique_id("e2e-hygiene")
    file_name = "#{file_base}.md"

    goto_back_office_live(page, "/bo/ingestion")

    page |> Page.locator("#new-folder-button") |> Locator.click!()
    page |> Page.locator("#new-folder-modal") |> Expect.to_be_visible!()
    page |> Page.locator("#new-folder-input") |> Locator.fill!(folder_name)
    page |> Page.locator("#create-folder-button") |> Locator.click!()
    page |> Page.locator("#new-folder-modal") |> Expect.to_be_hidden!()

    Locator.click!(folder_button(page, folder_name))
    page |> Page.locator("main") |> Expect.to_contain_text!(folder_name)

    add_raw_markdown(page, file_base, "# Hygiene v1\n\nInitial content for stale check.")
    select_file_row(page, file_name)
    ingest_selected_async(page, file_name)
    # Wait for the PubSub handle_info cycle: job_updated -> load_entries -> doc.updated_at = T1.
    Expect.to_contain_text!(file_row(page, file_name), "ingested")

    goto_back_office_live(page, "/bo/ingestion")
    Locator.click!(folder_button(page, folder_name))
    # Wait for the navigate event to be processed and the file row to appear.
    Expect.to_be_visible!(file_row(page, file_name))

    # Overwrite the file first, then bump mtime explicitly: File.write resets mtime to now and
    # would clobber a pre-write bump.
    write_e2e_file(
      request,
      "#{folder_name}/#{file_name}",
      "# Hygiene v2\n\nUpdated content should mark file stale."
    )

    touch_e2e_file(request, "#{folder_name}/#{file_name}")

    # Re-enter the folder so load_entries runs again and picks up the bumped mtime.
    goto_back_office_live(page, "/bo/ingestion")
    Locator.click!(folder_button(page, folder_name))
    Expect.to_contain_text!(file_row(page, file_name), "stale")

    Page.goto!(page, preview_path("#{folder_name}/#{file_name}"))

    page
    |> Page.locator("body")
    |> Expect.to_contain_text!("Updated content should mark file stale")
  end

  test "Journey 4: unsupported source chips are visible but disabled", %{page: page} do
    goto_back_office_live(page, "/bo/history")

    row =
      page
      |> Page.locator("tr", has_text: "E2E Unsupported Source Conversation")
      |> Locator.first()

    Expect.to_be_visible!(row)
    row |> Locator.get_by_text("E2E Unsupported Source Conversation") |> Locator.click!()

    Expect.to_have_url!(page, ~r{/bo/conversations/})

    page
    |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|)
    |> Locator.first()
    |> Expect.to_be_visible!()

    source_chip = page |> Page.locator(~s|[data-testid="source-chip"]|) |> Locator.first()
    Expect.to_be_visible!(source_chip)
    Expect.to_be_disabled!(source_chip)
    Expect.to_have_attribute!(source_chip, "title", "Preview unavailable")

    Locator.click!(source_chip, force: true)
    page |> Page.locator("#file-preview-modal") |> Expect.to_be_hidden!()
    Expect.to_have_url!(page, ~r{/bo/conversations/})
  end
end
