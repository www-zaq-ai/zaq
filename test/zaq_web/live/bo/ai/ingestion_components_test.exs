defmodule ZaqWeb.Live.BO.AI.IngestionComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Live.BO.AI.IngestionComponents

  # ---------------------------------------------------------------------------
  # file_icon/1 — one test per extension branch
  # ---------------------------------------------------------------------------

  describe "file_icon/1" do
    test "renders PDF icon for .pdf files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "report.pdf")

      assert html =~ "PDF"
      assert html =~ "#DC2626"
    end

    test "renders PPTX icon for .pptx files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "slides.pptx")

      assert html =~ "#FF8A65"
      assert html =~ "#E64A19"
    end

    test "renders DOCX icon for .docx files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "document.docx")

      assert html =~ "DOCX"
      assert html =~ "#2563EB"
    end

    test "renders XLSX icon for .xlsx files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "spreadsheet.xlsx")

      assert html =~ "XLSX"
      assert html =~ "#16A34A"
    end

    test "renders XLSX icon for .xls files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "spreadsheet.xls")

      assert html =~ "XLSX"
      assert html =~ "#16A34A"
    end

    test "renders image icon for .png files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "photo.png")

      assert html =~ "paint0_linear_103_1789"
    end

    test "renders image icon for .jpg files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "photo.jpg")

      assert html =~ "paint0_linear_103_1789"
    end

    test "renders image icon for .jpeg files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "photo.jpeg")

      assert html =~ "paint0_linear_103_1789"
    end

    test "renders CSV icon for .csv files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "data.csv")

      assert html =~ "CSV"
      assert html =~ "#059669"
    end

    test "renders MD icon for .md files" do
      html = render_component(&IngestionComponents.file_icon/1, name: "notes.md")

      assert html =~ "MD"
      assert html =~ "#0891B2"
    end

    test "renders generic document icon for unknown extensions" do
      html = render_component(&IngestionComponents.file_icon/1, name: "archive.zip")

      assert html =~ "currentColor"
      refute html =~ "PDF"
      refute html =~ "DOCX"
    end

    test "applies custom class attribute" do
      html = render_component(&IngestionComponents.file_icon/1, name: "doc.pdf", class: "w-8 h-8")

      assert html =~ ~s(class="w-8 h-8")
    end
  end

  # ---------------------------------------------------------------------------
  # status_color/1
  # ---------------------------------------------------------------------------

  describe "status_color/1" do
    test "returns correct class for each status" do
      assert IngestionComponents.status_color("pending") =~ "bg-black/5"
      assert IngestionComponents.status_color("processing") =~ "amber"
      assert IngestionComponents.status_color("completed") =~ "emerald"
      assert IngestionComponents.status_color("completed_with_errors") =~ "orange"
      assert IngestionComponents.status_color("failed") =~ "red"
      assert IngestionComponents.status_color("unknown") =~ "bg-black/5"
    end
  end

  # ---------------------------------------------------------------------------
  # upload_section/1 — folder_drop_skipped rendering
  # ---------------------------------------------------------------------------

  describe "upload_section/1 folder_drop_skipped" do
    defp build_uploads do
      # Minimal mock that satisfies the component's @uploads.files access
      %{
        files: %Phoenix.LiveView.UploadConfig{
          ref: "phx-upload-ref",
          entries: [],
          errors: [],
          name: :files,
          accept: :any,
          max_entries: 10,
          max_file_size: 20_000_000,
          chunk_size: 64_000,
          chunk_timeout: 10_000,
          external: false,
          auto_upload?: false,
          progress_event: nil
        }
      }
    end

    test "renders skipped section with 'unsupported format' for known reason" do
      html =
        render_component(&IngestionComponents.upload_section/1,
          uploads: build_uploads(),
          embedding_ready: true,
          folder_drop_skipped: [
            %{"name" => "x.json", "path" => "x.json", "reason" => "unsupported_format"}
          ]
        )

      assert html =~ "x.json"
      assert html =~ "unsupported format"
    end

    test "renders no skipped section when folder_drop_skipped is empty" do
      html =
        render_component(&IngestionComponents.upload_section/1,
          uploads: build_uploads(),
          embedding_ready: true,
          folder_drop_skipped: []
        )

      refute html =~ "Skipped"
      refute html =~ "data-testid=\"skipped-files\""
    end

    test "renders catch-all 'skipped' text for unknown reason" do
      html =
        render_component(&IngestionComponents.upload_section/1,
          uploads: build_uploads(),
          embedding_ready: true,
          folder_drop_skipped: [
            %{"name" => "mystery.bin", "path" => "mystery.bin", "reason" => "some_weird_reason"}
          ]
        )

      assert html =~ "mystery.bin"
      assert html =~ "skipped"
      refute html =~ "unsupported format"
    end

    test "upload button still renders when folder_drop_skipped is non-empty (regression guard)" do
      # Build uploads with one entry to trigger the upload button
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "phx-ref-1",
        uuid: "uuid-1",
        upload_ref: "phx-upload-ref",
        upload_config: :files,
        client_name: "test.md",
        client_size: 100,
        client_type: "text/markdown",
        client_relative_path: nil,
        done?: false,
        cancelled?: false,
        preflighted?: false,
        progress: 0,
        valid?: true
      }

      uploads = %{
        files: %Phoenix.LiveView.UploadConfig{
          ref: "phx-upload-ref",
          entries: [entry],
          errors: [],
          name: :files,
          accept: :any,
          max_entries: 10,
          max_file_size: 20_000_000,
          chunk_size: 64_000,
          chunk_timeout: 10_000,
          external: false,
          auto_upload?: false,
          progress_event: nil
        }
      }

      html =
        render_component(&IngestionComponents.upload_section/1,
          uploads: uploads,
          embedding_ready: true,
          folder_drop_skipped: [
            %{"name" => "x.json", "path" => "x.json", "reason" => "unsupported_format"}
          ]
        )

      assert html =~ "upload-files-button"
      assert html =~ "x.json"
    end
  end

  # ---------------------------------------------------------------------------
  # skip_reason/1
  # ---------------------------------------------------------------------------

  describe "skip_reason/1" do
    test "returns 'unsupported format' for unsupported_format" do
      assert IngestionComponents.skip_reason("unsupported_format") == "unsupported format"
    end

    test "catch-all returns 'skipped' for unknown reasons" do
      assert IngestionComponents.skip_reason("some_unknown_reason") == "skipped"
      assert IngestionComponents.skip_reason("another_weird_thing") == "skipped"
    end
  end
end
