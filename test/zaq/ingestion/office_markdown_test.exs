defmodule Zaq.Ingestion.OfficeMarkdownTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Ingestion.OfficeMarkdown
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, PptxToMd, XlsxToMd}

  @fixture_dir Path.expand("../../fixtures/offline_conversion", __DIR__)

  test "removes a DOCX data URI without removing its caption or changing nearby links" do
    markdown = """
    ## Résumé ![chart](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAA...) chart caption

    See [the source](https://example.org/report).
    """

    assert OfficeMarkdown.ignore_images(markdown) == """
           ## Résumé  chart caption

           See [the source](https://example.org/report).
           """
  end

  test "removes PPTX image references without breaking the table or neighboring prose" do
    markdown = """
    ## Slide 2

    | Visual | Notes |
    | --- | --- |
    | ![Picture 1](Picture%201.png) Sample | Count: 5 |
    | ![Picture 2](<Picture 2.png>) | [Details](details.md) |
    """

    assert OfficeMarkdown.ignore_images(markdown) == """
           ## Slide 2

           | Visual | Notes |
           | --- | --- |
           |  Sample | Count: 5 |
           |  | [Details](details.md) |
           """
  end

  test "leaves XLSX cells and literal image examples untouched" do
    markdown = """
    ## Sheet1

    | Item | Amount |
    | --- | --- |
    | Orchard | 15 |

    The literal `![sample](example.png)` stays.

    ```markdown
    ![example](example.png)
    ```
    """

    assert OfficeMarkdown.ignore_images(markdown) == markdown
  end

  test "removes multiline images without consuming surrounding lines" do
    assert OfficeMarkdown.ignore_images("Before ![two\nlines](photo.png) after\n") ==
             "Before  after\n"
  end

  @tag :tmp_dir
  test "retains text from the installed Office converters", %{tmp_dir: tmp_dir} do
    for {converter, fixture} <- [
          {DocxToMd, "google_drive_docx_export.docx"},
          {PptxToMd, "pptx_text_slide.pptx"},
          {XlsxToMd, "xlsx_data_table.xlsx"}
        ] do
      output = Path.join(tmp_dir, fixture <> ".md")
      assert {:ok, _} = converter.run(Path.join(@fixture_dir, fixture), output)
      markdown = File.read!(output)
      assert String.trim(markdown) != ""
      assert OfficeMarkdown.ignore_images(markdown) == markdown
    end
  end

  property "only image spans change, and repeated normalization is idempotent" do
    prefix = string(Enum.to_list(?a..?z) ++ ~c"éø漢 ", min_length: 1, max_length: 40)

    check all(caption <- prefix) do
      markdown = "Caption: #{caption} ![photo](Picture%201.png) / ![also](two.png)\r\n"
      expected = "Caption: #{caption}  / \r\n"

      assert OfficeMarkdown.ignore_images(markdown) == expected
      assert OfficeMarkdown.ignore_images(expected) == expected
    end
  end
end
