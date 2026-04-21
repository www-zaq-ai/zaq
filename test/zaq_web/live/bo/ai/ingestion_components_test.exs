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
end
