defmodule Zaq.Ingestion.BM25IndexManagerTest do
  use Zaq.DataCase, async: false

  @moduletag :integration

  alias Zaq.Ingestion.BM25IndexManager

  describe "init/0" do
    test "runs without error" do
      assert :ok = BM25IndexManager.init()
    end

    test "is idempotent — second call returns :ok without error" do
      assert :ok = BM25IndexManager.init()
      assert :ok = BM25IndexManager.init()
    end

    test "chunks_bm25_idx exists after init" do
      BM25IndexManager.init()

      alias Ecto.Adapters.SQL, as: EctoSQL

      {:ok, %{rows: rows}} =
        EctoSQL.query(
          Zaq.Repo,
          "SELECT 1 FROM pg_indexes WHERE indexname = 'chunks_bm25_idx'",
          []
        )

      assert rows != [], "chunks_bm25_idx should exist in pg_indexes"
    end
  end
end
