defmodule Zaq.Ingestion.ExternalSourceTest do
  use ExUnit.Case, async: true

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
end
