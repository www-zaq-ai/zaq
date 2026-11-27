defmodule Zaq.E2EPw.IngestionTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @ingestion_path "/bo/ingestion"
  @config_path "/bo/system-config"

  @warning_heading ~s|[data-testid="embedding-warning-title"]|
  @warning_link ~s|a[href="/bo/system-config?tab=embedding"]|
  @embedding_form "#embedding-config-form"
  @unlock_trigger ~s|[phx-click="unlock_embedding"]|
  @confirm_unlock ~s|[phx-click="confirm_unlock_embedding"]|
  @confirm_save ~s|[phx-click="confirm_save_embedding"]|
  @ingest_button "#ingest-selected-button"
  @upload_data_button "#upload-data-button"
  @upload_browse_trigger "#upload-form label"
  @upload_submit_button "#upload-files-button"

  # Minimal valid PDF bytes that DocumentProcessorFake (File.read) can ingest.
  @minimal_pdf "%PDF-1.0\n" <>
                 "1 0 obj<</Type /Catalog /Pages 2 0 R>>endobj\n" <>
                 "2 0 obj<</Type /Pages /Kids [3 0 R] /Count 1>>endobj\n" <>
                 "3 0 obj<</Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]>>endobj\n" <>
                 "xref\n0 4\n" <>
                 "0000000000 65535 f\n" <>
                 "0000000009 00000 n\n" <>
                 "0000000058 00000 n\n" <>
                 "0000000115 00000 n\n" <>
                 "trailer<</Size 4 /Root 1 0 R>>\n" <>
                 "startxref\n190\n%%EOF"

  # Ingestion
  setup %{page: page} do
    reset_e2e_state(Page.request(page))
    login_to_back_office(page)
    # Reset processor state so no leftover fail count from a previous run affects this test.
    processor(page, "/e2e/processor/reset")

    # afterEach: reset the processor again (the page's contexts close after on_exit callbacks).
    on_exit(fn -> processor(page, "/e2e/processor/reset") end)
    :ok
  end

  defp processor(page, path) do
    APIRequestContext.get!(Page.request(page), normalize_base_url() <> path)
  end

  defp write_temp_pdf(filename) do
    path = Path.join(System.tmp_dir!(), filename)
    File.write!(path, @minimal_pdf)
    path
  end

  # File row in the ingestion table: match the preview button title (stable across browsers).
  defp file_row(page, filename) do
    page
    |> Page.locator("#ingestion-file-list tr")
    |> Locator.filter(has: Page.locator(page, ~s|button[title="#{filename}"]|))
    |> Locator.first()
  end

  defp close_jobs_drawer(page) do
    drawer = Page.locator(page, "#ingestion-jobs-drawer")

    if Locator.is_visible!(drawer) do
      drawer |> Locator.get_by_role(:button, name: ~r/close drawer/i) |> Locator.click!()
      drawer |> Expect.not_() |> Expect.to_be_visible!(timeout: 5_000)
      wait_for_live_view_settled(page)
    end
  end

  defp expect_async_ingestion_started(page, filename) do
    toast = Page.locator(page, "#ingest-toast")
    Expect.to_be_visible!(toast, timeout: 15_000)
    Expect.to_contain_text!(toast, "Ingestion started.")
    drawer = Page.locator(page, "#ingestion-jobs-drawer")
    Expect.to_be_visible!(drawer, timeout: 15_000)

    drawer
    |> Locator.locator(".zaq-card-default")
    |> Locator.filter(has_text: filename)
    |> Locator.first()
    |> Expect.to_be_visible!(timeout: 15_000)
  end

  defp wait_for_async_row_badge(page, filename, badge) do
    terminal_status = if badge == "failed", do: "failed", else: "completed"
    drawer = Page.locator(page, "#ingestion-jobs-drawer")

    unless Locator.is_visible!(drawer) do
      page |> Page.locator("#monitor-jobs-button") |> Locator.click!()
      Expect.to_be_visible!(drawer, timeout: 10_000)
    end

    job_card =
      drawer
      |> Locator.locator(".zaq-card-default")
      |> Locator.filter(has_text: filename)
      |> Locator.first()

    job_card
    |> Locator.get_by_text(terminal_status, exact: true)
    |> Expect.to_be_visible!(timeout: 60_000)

    close_jobs_drawer(page)
    wait_for_live_view_settled(page)

    row = file_row(page, filename)

    if badge == "failed" do
      row |> Locator.locator("span", has_text: "failed") |> Expect.to_be_visible!(timeout: 15_000)

      row
      |> Locator.locator("span", has_text: "ingested")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    else
      row
      |> Locator.locator("span", has_text: "ingested")
      |> Expect.to_be_visible!(timeout: 15_000)
    end
  end

  # check() is idempotent, unlike a point-in-time isChecked() read.
  defp select_and_ingest(page, row, filename) do
    # Clear any stale flash FIRST so the "Ingestion started." check cannot match a leftover.
    dismiss_flash(page)
    close_jobs_drawer(page)
    wait_for_live_view_settled(page)
    checkbox = Locator.get_by_role(row, :checkbox)
    ingest_button = Page.locator(page, @ingest_button)
    Expect.to_be_visible!(checkbox)
    Locator.check!(checkbox)
    Expect.to_be_checked!(checkbox)
    wait_for_live_view_settled(page)
    # Wait for LiveView to re-enable the action before clicking.
    Expect.to_be_enabled!(ingest_button)
    Locator.click!(ingest_button)
    expect_async_ingestion_started(page, filename)
    # Dismiss the "Ingestion started." toast so a later call does not match on it.
    dismiss_flash(page)
  end

  defp open_upload_modal(page) do
    page |> Page.locator(@upload_data_button) |> Locator.click!()
    page |> Page.locator("#upload-modal") |> Expect.to_be_visible!()
  end

  defp upload(page, path) do
    chooser =
      Page.expect_file_chooser!(page, fn ->
        open_upload_modal(page)
        page |> Page.locator(@upload_browse_trigger) |> Locator.click!()
      end)

    Playwright.FileChooser.set_files!(chooser, path)
  end

  defp confirm_destructive_save(page) do
    page |> Page.get_by_role(:heading, name: "Delete All Embeddings?") |> Expect.to_be_visible!()

    expect_flash_during_action(page, "Embedding settings saved.", fn ->
      page |> Page.locator(@confirm_save) |> Locator.click!()
    end)

    dismiss_flash(page)
  end

  test "shows 'Embedding not configured' warning and link navigates to embedding tab", %{
    page: page
  } do
    goto_back_office_live(page, @ingestion_path)

    warning = Page.locator(page, @warning_heading, has_text: "Embedding not configured")
    # After /e2e/reset re-seeds the default embedding config, the chunks table exists and the
    # warning does NOT appear. This test is a guard for the truly-fresh-DB case; upstream skips
    # at runtime when the banner is absent (here: passes, ExUnit cannot skip a running test).
    visible = Locator.is_visible!(warning)

    if visible do
      Expect.to_be_visible!(warning)

      link = Page.locator(page, @warning_link)
      Expect.to_be_visible!(link)
      Locator.click!(link)

      page |> Page.locator(@embedding_form) |> Expect.to_be_visible!()
      Expect.to_have_url!(page, ~r/tab=embedding/)
    end
  end

  @tag timeout: 240_000
  test "ingest PDF shows ingested tag; changing model invalidates; job failure shows failed tag; re-ingest restores",
       %{page: page} do
    pdf_filename = "e2e-ingestion-#{System.system_time(:millisecond)}.pdf"

    # Reset seeded the embedding config, so there is no warning.
    goto_back_office_live(page, @ingestion_path)
    wait_for_live_view_settled(page)

    page
    |> Page.locator(@warning_heading, has_text: "Embedding not configured")
    |> Expect.not_()
    |> Expect.to_be_visible!()

    # Upload the PDF.
    temp_pdf_path = write_temp_pdf(pdf_filename)
    upload(page, temp_pdf_path)

    upload_btn = Page.locator(page, @upload_submit_button)
    Expect.to_be_visible!(upload_btn)
    Locator.click!(upload_btn)

    page |> Page.get_by_text(~r/file\(s\) uploaded\./) |> Expect.to_be_visible!()
    dismiss_flash(page)

    # Select the file and ingest.
    row = file_row(page, pdf_filename)
    Expect.to_be_visible!(row)

    select_and_ingest(page, row, pdf_filename)
    wait_for_async_row_badge(page, pdf_filename, "ingested")

    # Fail a re-ingest while "ingested" is still in the DB: the failed job must
    # override the "ingested" badge.
    processor(page, "/e2e/processor/fail?count=1")
    select_and_ingest(page, row, pdf_filename)
    wait_for_async_row_badge(page, pdf_filename, "failed")

    # Restore the "ingested" state before the model-change step.
    select_and_ingest(page, row, pdf_filename)
    wait_for_async_row_badge(page, pdf_filename, "ingested")

    # Change the embedding model (destructive save).
    goto_back_office_live(page, "#{@config_path}?tab=embedding")
    wait_for_live_view_settled(page)
    page |> Page.locator(@embedding_form) |> Expect.to_be_visible!()

    unlock_trigger = page |> Page.locator(@unlock_trigger) |> Locator.first()
    Expect.to_be_visible!(unlock_trigger)
    unlock_heading = Page.get_by_role(page, :heading, name: "Unlock Model Selection")

    # Retry the click: a DOM morph in flight can silently drop the phx-click event.
    Expect.to_pass!(
      fn ->
        wait_for_live_view_settled(page)
        Locator.click!(unlock_trigger)
        Expect.to_be_visible!(unlock_heading, timeout: 2_000)
      end,
      intervals: [500, 1_000, 2_000],
      timeout: 15_000
    )

    page |> Page.locator(@confirm_unlock) |> Locator.click!()
    page |> Page.locator(@unlock_trigger) |> Expect.not_() |> Expect.to_be_visible!()

    model_text_input = Page.locator(page, ~s|input[type="text"][name="embedding_config[model]"]|)

    # Only "custom" providers render a plain text input; upstream fixmes the test otherwise.
    if match?({:ok, true}, Locator.is_enabled(model_text_input, timeout: 2_000)) do
      new_model = "e2e-reset-model-#{System.system_time(:millisecond)}"
      Locator.fill!(model_text_input, new_model)
      Locator.press!(model_text_input, "Tab")

      save_btn = Page.get_by_role(page, :button, name: "Save Embedding Settings")
      Expect.to_have_class!(save_btn, ~r/\bzaq-btn-danger\b/, timeout: 5_000)
      Locator.click!(save_btn)

      confirm_destructive_save(page)

      # The "ingested" tag must be gone.
      goto_back_office_live(page, @ingestion_path)
      wait_for_live_view_settled(page)

      row_after_reset = file_row(page, pdf_filename)
      Expect.to_be_visible!(row_after_reset)

      row_after_reset
      |> Locator.locator("span", has_text: "ingested")
      |> Expect.not_()
      |> Expect.to_be_visible!()

      # Ingest with simulated failure -> "failed" tag.
      processor(page, "/e2e/processor/fail?count=1")
      select_and_ingest(page, row_after_reset, pdf_filename)
      wait_for_async_row_badge(page, pdf_filename, "failed")

      # Re-ingest (no failure) -> "ingested" tag returns.
      select_and_ingest(page, row_after_reset, pdf_filename)
      wait_for_async_row_badge(page, pdf_filename, "ingested")
    end
  end

  @tag timeout: 120_000
  test "renaming a folder keeps ingested file visible with ingested tag", %{page: page} do
    ts = System.system_time(:millisecond)
    folder_name = "zaq-rename-#{ts}"
    renamed_folder = "product-rename-#{ts}"
    pdf_filename = "e2e-in-folder-#{ts}.pdf"
    goto_back_office_live(page, @ingestion_path)
    wait_for_live_view_settled(page)

    # Create folder via UI
    page |> Page.locator("#new-folder-button") |> Locator.click!()
    page |> Page.locator("#new-folder-input") |> Expect.to_be_visible!()
    page |> Page.locator("#new-folder-input") |> Locator.fill!(folder_name)

    page
    |> Page.locator("#new-folder-form")
    |> Locator.get_by_role(:button, name: ~r/create/i)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    # Navigate into the new folder
    page |> Page.get_by_role(:button, name: folder_name) |> Locator.click!()
    wait_for_live_view_settled(page)

    # Upload a PDF into the folder
    upload(page, write_temp_pdf(pdf_filename))
    page |> Page.locator(@upload_submit_button) |> Locator.click!()
    dismiss_flash(page)

    # Ingest the uploaded PDF
    row = file_row(page, pdf_filename)
    Expect.to_be_visible!(row, timeout: 10_000)
    select_and_ingest(page, row, pdf_filename)
    wait_for_async_row_badge(page, pdf_filename, "ingested")

    # Navigate back to root
    page |> Page.get_by_role(:button, name: "root") |> Locator.click!()
    wait_for_live_view_settled(page)

    # Rename the folder
    folder_row = file_row(page, folder_name)
    Expect.to_be_visible!(folder_row)
    folder_row |> Locator.locator(~s|button[phx-click="rename_item"]|) |> Locator.click!()

    rename_input = Page.locator(page, ~s|input[name="name"]|)
    Expect.to_be_visible!(rename_input)
    Locator.fill!(rename_input, renamed_folder)

    page
    |> Page.locator("form[phx-submit='confirm_rename']")
    |> Locator.get_by_role(:button, name: ~r/rename/i)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    # Navigate into the renamed folder
    page |> Page.get_by_role(:button, name: renamed_folder) |> Locator.click!()
    wait_for_live_view_settled(page)

    # The PDF must still show the "ingested" tag, proving Document.source was updated.
    Expect.to_be_visible!(file_row(page, pdf_filename))

    file_row(page, pdf_filename)
    |> Locator.locator("span", has_text: "ingested")
    |> Expect.to_be_visible!()
  end

  test "uploading duplicate filename creates stem(1).ext instead of overwriting", %{page: page} do
    base_name = "e2e-dedup-#{System.system_time(:millisecond)}"
    pdf_filename = "#{base_name}.pdf"
    dedup_filename = "#{base_name}(1).pdf"

    goto_back_office_live(page, @ingestion_path)
    wait_for_live_view_settled(page)

    temp_pdf_path = write_temp_pdf(pdf_filename)

    # First upload
    upload(page, temp_pdf_path)
    page |> Page.locator(@upload_submit_button) |> Locator.click!()
    page |> Page.get_by_text(~r/file\(s\) uploaded\./) |> Expect.to_be_visible!()
    dismiss_flash(page)
    Expect.to_be_visible!(file_row(page, pdf_filename))

    # Second upload of the same file
    upload(page, temp_pdf_path)
    page |> Page.locator(@upload_submit_button) |> Locator.click!()
    page |> Page.get_by_text(~r/file\(s\) uploaded\./) |> Expect.to_be_visible!()

    # Original must still exist and the deduplicated name must appear.
    Expect.to_be_visible!(file_row(page, pdf_filename))
    Expect.to_be_visible!(file_row(page, dedup_filename))
  end
end
