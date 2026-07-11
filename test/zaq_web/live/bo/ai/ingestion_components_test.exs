defmodule ZaqWeb.Live.BO.AI.IngestionComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.IngestionFileGridView
  alias ZaqWeb.Components.DesignSystem.IngestionFileListView
  alias ZaqWeb.Components.DesignSystem.IngestionFileStatus
  alias ZaqWeb.Live.BO.AI.IngestionComponents

  # Matches ZaqWeb.Live.BO.AI.IngestionComponents.file_icon/1 image branch (unique SVG gradient ids).
  defp image_file_gradient_id(name), do: "img-gradient-#{:erlang.phash2(name)}"

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
      name = "photo.png"
      html = render_component(&IngestionComponents.file_icon/1, name: name)
      id = image_file_gradient_id(name)

      assert html =~ id
      assert html =~ "url(##{id})"
    end

    test "renders image icon for .jpg files" do
      name = "photo.jpg"
      html = render_component(&IngestionComponents.file_icon/1, name: name)
      id = image_file_gradient_id(name)

      assert html =~ id
      assert html =~ "url(##{id})"
    end

    test "renders image icon for .jpeg files" do
      name = "photo.jpeg"
      html = render_component(&IngestionComponents.file_icon/1, name: name)
      id = image_file_gradient_id(name)

      assert html =~ id
      assert html =~ "url(##{id})"
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
  # status_pill_classes/1
  # ---------------------------------------------------------------------------

  describe "status_pill_classes/1" do
    test "returns correct semantic modifier for each status" do
      assert "zaq-pill" in IngestionComponents.status_pill_classes("pending")
      assert "zaq-pill--elevated" in IngestionComponents.status_pill_classes("pending")
      assert "zaq-pill--accent" in IngestionComponents.status_pill_classes("processing")
      assert "zaq-pill--success" in IngestionComponents.status_pill_classes("completed")

      assert "zaq-pill--warning" in IngestionComponents.status_pill_classes(
               "completed_with_errors"
             )

      assert "zaq-pill--danger" in IngestionComponents.status_pill_classes("failed")
      assert "zaq-pill--elevated" in IngestionComponents.status_pill_classes("unknown")
    end
  end

  describe "delegated helpers" do
    test "file_icon_color/1 returns semantic classes by extension" do
      assert IngestionComponents.file_icon_color("report.pdf") == "text-red-400"
      assert IngestionComponents.file_icon_color("notes.md") == "zaq-text-accent"
      assert IngestionComponents.file_icon_color("archive.zip") == "text-black/30"
    end

    test "folder_count_pill_classes/1 returns success and warning variants" do
      assert "zaq-pill--success" in IngestionComponents.folder_count_pill_classes(true)
      assert "zaq-pill--warning" in IngestionComponents.folder_count_pill_classes(false)
    end

    test "renders embedding configuration warning banner" do
      html = render_component(&IngestionComponents.ingestion_embedding_banner/1, %{})

      assert html =~ "embedding-warning-title"
      assert html =~ "Embedding not configured"
      assert html =~ "/bo/system-config?tab=embedding"
    end
  end

  describe "ingestion file status helpers" do
    test "file_ingestion_status applies defaults around partial map entries" do
      status =
        IngestionFileStatus.file_ingestion_status(%{"notes.md" => %{stale?: true}}, "notes.md")

      assert status.stale?
      assert status.ingested_at == nil
      assert status.job_status == nil
      assert status.permissions_count == 0
      refute status.is_public
      refute status.can_share?
    end

    test "renders provider-mode shared badge as permission button" do
      html =
        render_component(&IngestionFileStatus.shared_badge/1,
          provider_mode: true,
          permissions_count: 7,
          path: "provider-file-1"
        )

      assert html =~ ~s(<button)
      assert html =~ ~s(type="button")
      assert html =~ ~s(phx-click="view_provider_permissions")
      assert html =~ ~s(phx-value-path="provider-file-1")
      assert html =~ "Permissions are managed in the data source"
      assert html =~ "shared"
      refute html =~ "Shared with 7 person(s)/team(s)"
    end

    test "renders local shared badge as share button with permissions title" do
      html =
        render_component(&IngestionFileStatus.shared_badge/1,
          provider_mode: false,
          permissions_count: 3,
          path: "local-file.md"
        )

      assert html =~ ~s(<button)
      assert html =~ "zaq-pill zaq-pill--shared zaq-text-caption"
      assert html =~ ~s(phx-click="share_item")
      assert html =~ ~s(phx-value-path="local-file.md")
      assert html =~ ~s[title="Shared with 3 person(s)/team(s)"]
      assert html =~ "shared"
      refute html =~ ~s(phx-click="view_provider_permissions")
      refute html =~ "Permissions are managed in the data source"
    end

    test "record helpers support fallback shapes and related record variants" do
      assert IngestionFileStatus.record_path(%{name: "fallback.md"}) == "fallback.md"
      assert IngestionFileStatus.record_file?(%{kind: :file})
      assert IngestionFileStatus.record_folder?(%{kind: "folder"})
      assert IngestionFileStatus.record_folder?(%{type: :directory})

      assert IngestionFileStatus.related_record(%{
               attributes: %{related_record: %{name: "side.md"}}
             }) ==
               %{name: "side.md"}

      assert IngestionFileStatus.related_record(%{}) == nil
      assert IngestionFileStatus.related_record_name(%{name: "side.md"}) == "side.md"
      assert IngestionFileStatus.related_record_path(%{path: "side.md"}) == "side.md"
      assert IngestionFileStatus.related_record_size(%{size: 12}) == 12
    end
  end

  describe "list view rendering" do
    test "applies selected row variant when entry is in selected set" do
      html =
        render_component(&IngestionFileListView.file_list_view/1,
          entries: [
            %{name: "alpha.md", type: :file, size: 10, modified_at: ~U[2026-01-01 00:00:00Z]}
          ],
          selected: MapSet.new(["alpha.md"]),
          current_dir: ".",
          current_volume: "default",
          ingestion_map: %{}
        )

      assert html =~ "zaq-table-row--selected"
    end
  end

  describe "grid view rendering" do
    test "renders empty directory state" do
      html =
        render_component(&IngestionFileGridView.file_grid_view/1,
          entries: [],
          selected: MapSet.new(),
          current_dir: ".",
          current_volume: "default",
          ingestion_map: %{}
        )

      assert html =~ "Empty directory"
    end

    test "renders folder stats with completed count and fallback dash for empty folder size" do
      html =
        render_component(&IngestionFileGridView.file_grid_view/1,
          entries: [
            %{name: "docs", kind: "folder", path: "docs"},
            %{name: "empty", type: :directory, path: "empty"}
          ],
          selected: MapSet.new(["docs"]),
          current_dir: ".",
          current_volume: "default",
          ingestion_map: %{
            "docs" => %{total_size: 2048, file_count: 3, ingested_count: 3},
            "empty" => %{total_size: 0, file_count: 0, ingested_count: 0}
          }
        )

      assert html =~ "2.0 KB"
      assert html =~ "3/3"
      assert html =~ <<0xE2, 0x80, 0x94>>
      assert html =~ "zaq-ingestion-file-grid-card--selected"
    end

    test "renders ingested public and related sidecar indicators" do
      html =
        render_component(&IngestionFileGridView.file_grid_view/1,
          entries: [
            %{
              name: "report.pdf",
              path: "report.pdf",
              kind: :file,
              size: 4096,
              attributes: %{
                "related_record" => %{
                  "name" => "report.md",
                  "path" => "report.md",
                  "size" => 1024
                }
              }
            }
          ],
          selected: MapSet.new(),
          current_dir: ".",
          current_volume: "default",
          ingestion_map: %{
            "report.pdf" => %{
              ingested_at: ~U[2026-06-23 06:00:00Z],
              stale?: false,
              permissions_count: 2,
              is_public: true,
              can_share?: true
            }
          }
        )

      assert html =~ "ingested"
      assert html =~ "shared"
      assert html =~ "public"
      assert html =~ "report.md"
      assert html =~ "1.0 KB"
      assert html =~ ~s(phx-value-path="default/report.md")
    end

    test "renders shared and public indicators without ingested status" do
      html =
        render_component(&IngestionFileGridView.file_grid_view/1,
          entries: [%{name: "draft.md", kind: :file, size: 10}],
          selected: MapSet.new(),
          current_dir: ".",
          current_volume: "default",
          ingestion_map: %{
            "draft.md" => %{permissions_count: 1, is_public: true, can_share?: false}
          }
        )

      assert html =~ "shared"
      assert html =~ "public"
      refute html =~ "ingested"
      refute html =~ ~s(title="Share with roles")
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
      refute html =~ ~s/data-testid="skipped-files"/
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
      assert IngestionComponents.skip_reason(~s/some_unknown_reason/) == ~s/skipped/
      assert IngestionComponents.skip_reason(~s/another_weird_thing/) == ~s/skipped/
    end
  end
end
