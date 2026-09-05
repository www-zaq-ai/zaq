defmodule ZaqWeb.Components.DesignSystem.DropzoneTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.UploadConfig
  alias Phoenix.LiveView.UploadEntry
  alias ZaqWeb.Components.DesignSystem.Dropzone

  defp upload_config(name, entries \\ []) do
    %UploadConfig{
      ref: "phx-upload-ref",
      entries: entries,
      errors: [],
      name: name,
      accept: :any,
      max_entries: 10,
      max_file_size: 20_000_000,
      chunk_size: 64_000,
      chunk_timeout: 10_000,
      external: false,
      auto_upload?: false,
      progress_event: nil
    }
  end

  defp entry(ref \\ "phx-ref-1") do
    %UploadEntry{
      ref: ref,
      upload_ref: "phx-upload-ref",
      uuid: "uuid-#{ref}",
      valid?: true,
      progress: 100,
      preflighted?: true,
      done?: false,
      cancelled?: false,
      client_name: "report.pdf",
      client_size: 1024,
      client_type: "application/pdf",
      client_relative_path: nil,
      client_last_modified: nil
    }
  end

  describe "upload_section/1 defaults" do
    # IngestionLive passes none of the optional attrs and its JS hooks + handle_event
    # clauses are bound to these exact ids and event names. If a default changes, the
    # ingestion upload silently stops working — so pin them here.
    test "renders the ingestion ids, events and copy when nothing is configured" do
      html =
        render_component(&Dropzone.upload_section/1, uploads: %{files: upload_config(:files)})

      assert html =~ ~s(id="upload-form")
      assert html =~ ~s(id="upload-drop-zone")
      assert html =~ ~s(phx-submit="upload")
      assert html =~ ~s(phx-change="validate_upload")
      assert html =~ ~s(phx-hook="FolderDrop")
      assert html =~ "Upload"
      assert html =~ ".md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg — max 20 MB"
    end

    test "renders the submit button and cancel event for a queued entry" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: upload_config(:files, [entry()])}
        )

      assert html =~ ~s(id="upload-files-button")
      assert html =~ ~s(phx-click="cancel_upload")
      assert html =~ "Upload 1 file(s)"
      assert html =~ "report.pdf"
    end
  end

  describe "upload_section/1 configured" do
    test "uses a custom upload name, id prefix, events and copy" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{skill_resources: upload_config(:skill_resources, [entry()])},
          upload_name: :skill_resources,
          id_prefix: "skill-resource",
          submit_event: "upload_skill_resource",
          change_event: "validate_skill_resource",
          cancel_event: "cancel_skill_resource",
          label: "Reference file",
          submit_label: "Add",
          hint: ".md .pdf — max 20 MB",
          folder_drop?: false
        )

      assert html =~ ~s(id="skill-resource-form")
      assert html =~ ~s(id="skill-resource-drop-zone")
      assert html =~ ~s(id="skill-resource-files-button")
      assert html =~ ~s(phx-submit="upload_skill_resource")
      assert html =~ ~s(phx-change="validate_skill_resource")
      assert html =~ ~s(phx-click="cancel_skill_resource")
      assert html =~ "Reference file"
      assert html =~ "Add 1 file(s)"
      assert html =~ ".md .pdf — max 20 MB"
    end

    test "passes through a browser accept override" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{skill_resources: upload_config(:skill_resources)},
          upload_name: :skill_resources,
          input_accept: ".md,.pdf,.txt"
        )

      assert html =~ ~s(accept=".md,.pdf,.txt")
    end

    test "omits the FolderDrop hook when folder_drop? is false" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{skill_resources: upload_config(:skill_resources)},
          upload_name: :skill_resources,
          folder_drop?: false
        )

      refute html =~ "FolderDrop"
    end

    test "omits the inline submit control when show_submit? is false" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: upload_config(:files, [entry()])},
          show_submit?: false
        )

      refute html =~ "upload-files-button"
      refute html =~ "Upload 1 file(s)"
    end

    test "two dropzones in one document produce distinct element ids" do
      ingestion =
        render_component(&Dropzone.upload_section/1, uploads: %{files: upload_config(:files)})

      skill =
        render_component(&Dropzone.upload_section/1,
          uploads: %{skill_resources: upload_config(:skill_resources)},
          upload_name: :skill_resources,
          id_prefix: "skill-resource"
        )

      refute ingestion =~ "skill-resource-form"
      refute skill =~ ~s(id="upload-form")
    end
  end

  describe "upload_section/1 states" do
    test "hides the submit button when nothing is queued" do
      html =
        render_component(&Dropzone.upload_section/1, uploads: %{files: upload_config(:files)})

      refute html =~ "upload-files-button"
    end

    test "disables the submit button when embeddings are not ready" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: upload_config(:files, [entry()])},
          embedding_ready: false
        )

      assert html =~ "disabled"
    end

    test "uses a custom too_large_message when configured" do
      entry = entry()
      upload = upload_config(:files, [entry])

      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: %{upload | errors: [{entry.ref, :too_large}]}},
          too_large_message: "File exceeds 1 MB limit."
        )

      assert html =~ "File exceeds 1 MB limit."
      refute html =~ "File exceeds 20 MB limit."
    end

    test "renders the too many files error" do
      entry = entry()
      upload = upload_config(:files, [entry])

      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: %{upload | errors: [{entry.ref, :too_many_files}]}}
        )

      assert html =~ "Too many files selected (max 10)."
      refute html =~ "Upload failed."
    end

    test "renders the generic upload error for an unknown reason" do
      entry = entry()
      upload = upload_config(:files, [entry])

      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: %{upload | errors: [{entry.ref, :unexpected_upload_error}]}}
        )

      assert html =~ "Upload failed."
      refute html =~ "Too many files selected (max 10)."
      refute html =~ "File type not supported."
    end

    test "renders skipped folder entries with their reason" do
      html =
        render_component(&Dropzone.upload_section/1,
          uploads: %{files: upload_config(:files)},
          folder_drop_skipped: [
            %{"name" => "notes.key", "path" => "deck/notes.key", "reason" => "unsupported_format"}
          ]
        )

      assert html =~ ~s(data-testid="skipped-files")
      assert html =~ "notes.key"
      assert html =~ "unsupported format"
    end
  end

  describe "submit_button_label/2" do
    test "formats the shared submit copy" do
      assert Dropzone.submit_button_label("Import", []) == "Import 0 file(s)"
      assert Dropzone.submit_button_label("Upload", [%{}]) == "Upload 1 file(s)"
    end
  end

  describe "skip_reason/1" do
    test "maps the known reason and falls back for anything else" do
      assert Dropzone.skip_reason("unsupported_format") == "unsupported format"
      assert Dropzone.skip_reason("whatever") == "skipped"
      assert Dropzone.skip_reason(nil) == "skipped"
    end
  end
end
