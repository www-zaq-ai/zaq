defmodule Zaq.Materialization.RegistryTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Ingestion.Materializers.DiskDocument
  alias Zaq.Materialization.Registry

  test "returns allowlisted materializers" do
    assert {:ok, DataSourceDocument} = Registry.lookup("data_source_document")
    assert {:ok, DiskDocument} = Registry.lookup("disk_document")
  end

  test "rejects unknown materializers without dynamic atoms" do
    assert {:error, {:unknown_materializer, "agent_selected_action"}} =
             Registry.lookup("agent_selected_action")

    assert {:error, {:unknown_materializer, :data_source_document}} =
             Registry.lookup(:data_source_document)
  end
end
