defmodule Zaq.Ingestion.OfflineConversionContractTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.{Document, DocumentProcessor}

  @fixture_dir Path.expand("../../fixtures/offline_conversion", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "zaq_offline_conversion_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  for {extension, fixture_name, expected_text} <- [
        {"pdf", "pdf_text_page.pdf", "ZAQ 568 PDF contract: amber lantern guides the archive."},
        {"pptx", "pptx_text_slide.pptx",
         "ZAQ 568 PPTX contract: cobalt compass marks the route."},
        {"xlsx", "xlsx_data_table.xlsx", "silver orchard records the total"},
        {"md", "markdown_prose.md", "The cedar notebook preserves local prose."},
        {"csv", "csv_data_table.csv", "The violet harbor lists arrivals"}
      ] do
    test "prepares genuine #{String.upcase(extension)} content", %{root: root} do
      extension = unquote(extension)
      expected_text = unquote(expected_text)
      fixture = Path.join(@fixture_dir, unquote(fixture_name))
      path = Path.join(root, "contract.#{extension}")
      File.cp!(fixture, path)

      assert {:ok, %Document{} = document, _payloads} =
               DocumentProcessor.prepare_file_chunks(path, [])

      assert document.content =~ expected_text
      assert String.valid?(document.content)

      if extension in ~w(pdf pptx xlsx) do
        refute String.starts_with?(document.content, "PK")
        refute String.starts_with?(document.content, "%PDF")
        refute document.content =~ <<0>>
        refute document.content =~ "[Content_Types].xml"
        refute document.content =~ ~r/<(?:\?xml|p:sld|worksheet)\b/
      end

      if extension == "csv" do
        assert document.content =~ ~r/\|\s*Record\s*\|\s*Meaning\s*\|/
      end
    end
  end
end
