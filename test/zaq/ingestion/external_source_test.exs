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

  test "sidecar paths remain distinct for similarly sanitized provider file ids" do
    attrs = %{"provider" => "google_drive", "config_id" => "cfg"}

    path_a =
      ExternalSource.sidecar_relative_path(%Record{
        id: "a",
        kind: :file,
        attributes: Map.put(attrs, "provider_record_id", "file/1")
      })

    path_b =
      ExternalSource.sidecar_relative_path(%Record{
        id: "b",
        kind: :file,
        attributes: Map.put(attrs, "provider_record_id", "file:1")
      })

    assert path_a != path_b
    assert String.starts_with?(path_a, ".external-sidecars/google_drive-")
    assert String.ends_with?(path_a, ".md")
  end

  property "sidecar paths are relative and do not expose raw separators from identifiers" do
    check all(
            provider <- StreamData.string(:printable, min_length: 1, max_length: 20),
            config_id <- StreamData.string(:printable, min_length: 1, max_length: 20),
            file_id <- StreamData.string(:printable, min_length: 1, max_length: 20)
          ) do
      path =
        ExternalSource.sidecar_relative_path(%Record{
          id: file_id,
          kind: :file,
          attributes: %{
            "provider" => provider,
            "config_id" => config_id,
            "provider_record_id" => file_id
          }
        })

      assert String.starts_with?(path, ".external-sidecars/")
      assert String.ends_with?(path, ".md")
      refute Path.type(path) == :absolute
      refute ".." in Path.split(path)
      assert length(Path.split(path)) == 4
    end
  end
end
