defmodule Zaq.Ingestion.EnrichmentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Chunk, Document}

  test "enrich_records/1 reports indexed state from chunks, not just document rows" do
    source = "data_source/disk/archives/storage-entry-1"
    {:ok, document} = Document.create(%{source: source, content: "# guide"})

    record = %Record{
      id: "storage-entry-1",
      kind: :file,
      name: "guide.md",
      attributes: %{
        "provider" => "disk",
        "config_id" => "archives",
        "provider_record_id" => "storage-entry-1"
      }
    }

    assert {:ok, %{^source => status}} = Ingestion.enrich_records([record])
    assert status.document_id == document.id
    assert status.indexed? == false
    assert status.ingested_at == nil
    assert status.permissions_count == 0

    {:ok, _chunk} =
      Chunk.create(%{
        document_id: document.id,
        content: "guide",
        chunk_index: 0,
        embedding: List.duplicate(0.0, 1536)
      })

    assert {:ok, %{^source => status}} = Ingestion.enrich_records([record])
    assert status.indexed? == true
    assert status.ingested_at == document.updated_at

    {:ok, person} =
      People.create_person(%{
        full_name: "Enrichment User",
        email: "enrichment-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, _permission} =
      Ingestion.set_document_permission(document.id, :person, person.id, ["read"])

    assert {:ok, %{^source => status}} = Ingestion.enrich_records([record])
    assert status.permissions_count == 1
  end
end
