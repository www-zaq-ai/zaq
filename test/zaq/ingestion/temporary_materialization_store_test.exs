defmodule Zaq.Ingestion.TemporaryMaterializationStoreTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.TemporaryMaterializationStore

  test "writes markdown content in an isolated temporary root" do
    record = record("markdown-file")

    assert {:ok, stored} = TemporaryMaterializationStore.write_markdown(record, "# Temp")
    assert File.read!(stored.absolute_path) == "# Temp"
    assert stored.relative_path =~ ".md"
    assert String.contains?(stored.root_path, "zaq_temporary_materializations")

    File.rm_rf!(stored.root_path)
  end

  test "writes original binary content in an isolated temporary root" do
    record = record("binary-file")

    assert {:ok, stored} =
             TemporaryMaterializationStore.write_original(record, <<1, 2, 3>>, ".pdf")

    assert File.read!(stored.absolute_path) == <<1, 2, 3>>
    assert String.ends_with?(stored.relative_path, ".pdf")

    File.rm_rf!(stored.root_path)
  end

  defp record(id) do
    %Record{
      id: id,
      name: id,
      kind: :file,
      attributes: %{"provider" => "test", "config_id" => "1"}
    }
  end
end
