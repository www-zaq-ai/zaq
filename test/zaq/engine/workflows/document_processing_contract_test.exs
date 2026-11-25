defmodule Zaq.Engine.Workflows.DocumentProcessingContractTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.DataSource.{CreateDocument, DownloadDocument}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Workflows.Steps.EdgeStep

  test "a mapped, serialized download result keeps its materialized representation" do
    bytes = <<"%PDF-1.7", 0, 255>>
    encoded = Base.encode64(bytes)

    assert {:ok, record} =
             Provenance.seal(%Record{
               id: "source-1",
               kind: :file,
               name: "report.pdf",
               mime_type: "application/pdf",
               content: encoded,
               attributes: %{"encoding" => "base64"}
             })

    assert {:ok, %{record: ^record}} = DownloadDocument.validate_output(%{record: record})

    fact = %{__cascade__: %{"download" => Jason.decode!(Jason.encode!(%{record: record}))}}
    assert %{record: mapped} = EdgeStep.apply_mapping(fact, %{"record" => "download.record"})

    assert {:ok, %{record: restored}} = DownloadDocument.validate_output(%{record: mapped})
    assert restored.name == "report.pdf"
    assert restored.mime_type == "application/pdf"
    assert Map.get(restored.attributes, "encoding", restored.attributes[:encoding]) == "base64"
    assert Base.decode64!(restored.content) == bytes
  end

  test "Markdown export can bind CreateDocument arguments while keeping the destination explicit" do
    markdown = "# Report\n\nGenerated from a source document."

    fact = %{
      provider: "disk",
      parent_id: "selected-folder",
      __cascade__: %{
        "convert" => %{
          "content" => markdown,
          "name" => "report.md",
          "mime_type" => "text/markdown"
        }
      }
    }

    args =
      fact
      |> EdgeStep.apply_mapping(%{
        "content" => "convert.content",
        "name" => "convert.name",
        "mime_type" => "convert.mime_type"
      })
      |> Map.delete(:__cascade__)

    assert {:ok,
            %{
              provider: "disk",
              parent_id: "selected-folder",
              content: ^markdown,
              name: "report.md",
              mime_type: "text/markdown"
            }} = CreateDocument.validate_params(args)
  end
end
