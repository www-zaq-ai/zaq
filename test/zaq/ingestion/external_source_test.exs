defmodule Zaq.Ingestion.ExternalSourceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.ExternalSource

  test "config_id/1 returns nil when no config id attribute is present" do
    record = %Record{id: "file-1", kind: :file, attributes: %{}}

    assert ExternalSource.config_id(record) == nil
  end

  test "attribute lookups return nil when record attributes are not a map" do
    record = %Record{id: "file-1", kind: :file, attributes: nil}

    assert ExternalSource.provider(record) == nil
    assert ExternalSource.config_id(record) == nil
    refute ExternalSource.external?(record)
  end

  test "source keeps distinct provider file ids" do
    attrs = %{"provider" => "google_drive", "config_id" => "cfg"}

    source_a =
      ExternalSource.source(%Record{
        id: "a",
        kind: :file,
        attributes: Map.put(attrs, "provider_record_id", "file/1")
      })

    source_b =
      ExternalSource.source(%Record{
        id: "b",
        kind: :file,
        attributes: Map.put(attrs, "provider_record_id", "file:1")
      })

    assert source_a != source_b
    assert source_a == "data_source/google_drive/cfg/file/1"
  end

  property "source preserves the data source namespace and record identity" do
    check all(
            provider <- StreamData.string(:printable, min_length: 1, max_length: 20),
            config_id <- StreamData.string(:printable, min_length: 1, max_length: 20),
            file_id <- StreamData.string(:printable, min_length: 1, max_length: 20)
          ) do
      source =
        ExternalSource.source(%Record{
          id: file_id,
          kind: :file,
          attributes: %{
            "provider" => provider,
            "config_id" => config_id,
            "provider_record_id" => file_id
          }
        })

      assert String.starts_with?(source, "data_source/")
      assert source == Enum.join(["data_source", provider, config_id, file_id], "/")
    end
  end
end
