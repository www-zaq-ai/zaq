defmodule Zaq.Ingestion.ConnectorRegistryTest do
  use ExUnit.Case, async: false

  alias Zaq.Ingestion.ConnectorRegistry

  setup do
    original = Application.get_env(:zaq, Zaq.Ingestion)
    on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, original || []) end)
    :ok
  end

  describe "list_connectors/0" do
    test "returns a single default connector when only base_path is configured" do
      Application.put_env(:zaq, Zaq.Ingestion, base_path: "/tmp")
      connectors = ConnectorRegistry.list_connectors()
      assert length(connectors) == 1
      assert hd(connectors).icon == :folder
    end

    test "returns one entry per configured volume" do
      Application.put_env(:zaq, Zaq.Ingestion,
        volumes: %{"docs" => "/tmp/docs", "archive" => "/tmp/archive"}
      )

      connectors = ConnectorRegistry.list_connectors()
      assert length(connectors) == 2
    end

    test "each entry has id, label, and icon fields" do
      Application.put_env(:zaq, Zaq.Ingestion, volumes: %{"docs" => "/tmp/docs"})
      [connector] = ConnectorRegistry.list_connectors()
      assert connector == %{id: "docs", label: "docs", icon: :folder}
    end

    test "entries are sorted alphabetically by volume name" do
      Application.put_env(:zaq, Zaq.Ingestion,
        volumes: %{"zebra" => "/tmp/z", "alpha" => "/tmp/a", "mango" => "/tmp/m"}
      )

      ids = ConnectorRegistry.list_connectors() |> Enum.map(& &1.id)
      assert ids == ["alpha", "mango", "zebra"]
    end
  end
end
