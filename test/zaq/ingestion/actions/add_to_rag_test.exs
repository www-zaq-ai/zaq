defmodule Zaq.Ingestion.Actions.AddToRagTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.Actions.AddToRag

  describe "run/2" do
    test "returns ingested_count and failed_count on success" do
      params = %{
        document_id: Ecto.UUID.generate(),
        results: [],
        ingested_count: 5,
        failed_count: 0
      }

      assert {:ok, %{ingested_count: 5, failed_count: 0}} = AddToRag.run(params, %{})
    end

    test "passes through non-zero failed_count" do
      params = %{
        document_id: Ecto.UUID.generate(),
        results: [],
        ingested_count: 3,
        failed_count: 2
      }

      assert {:ok, %{ingested_count: 3, failed_count: 2}} = AddToRag.run(params, %{})
    end

    test "succeeds with zero ingested" do
      params = %{
        document_id: Ecto.UUID.generate(),
        results: [],
        ingested_count: 0,
        failed_count: 0
      }

      assert {:ok, %{ingested_count: 0, failed_count: 0}} = AddToRag.run(params, %{})
    end
  end
end
