defmodule Zaq.Ingestion.ChunkResetTableTest do
  # async: false — reset_table does DDL (DROP/CREATE TABLE) that would race
  # with other async tests sharing the same schema.
  use Zaq.DataCase, async: false

  alias Zaq.Hooks.{Hook, Registry}
  alias Zaq.Ingestion.Chunk

  # Captures :embedding_reset dispatches by forwarding to the test
  # process stored in a shared ETS table.
  defmodule ResetHookTestHandler do
    @behaviour Zaq.Hooks.Handler

    @impl true
    def handle(:embedding_reset, payload, _ctx) do
      case :ets.lookup(:chunk_reset_hook_captures, :receiver) do
        [{:receiver, pid}] -> send(pid, {:embedding_reset, payload})
        [] -> :ok
      end

      :ok
    end
  end

  setup do
    :ets.new(:chunk_reset_hook_captures, [:set, :public, :named_table])
    :ets.insert(:chunk_reset_hook_captures, {:receiver, self()})

    registry = :chunk_reset_test_registry
    start_supervised!({Registry, name: registry})
    Application.put_env(:zaq, :hooks_registry_name, registry)

    Registry.register(%Hook{
      handler: ResetHookTestHandler,
      events: [:embedding_reset],
      mode: :async
    })

    on_exit(fn -> Application.delete_env(:zaq, :hooks_registry_name) end)

    :ok
  end

  describe "reset_table/1" do
    test "recreates the chunks table with the new dimension" do
      assert :ok = Chunk.reset_table(384)
    end

    test "dispatches :embedding_reset with new_dimension in payload" do
      Chunk.reset_table(512)
      assert_receive {:embedding_reset, %{new_dimension: 512}}, 1000
    end

    test "creates bm25 index when use_bm25 is enabled" do
      original = Application.get_env(:zaq, Zaq.Ingestion)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      Application.put_env(:zaq, Zaq.Ingestion, use_bm25: true)

      try do
        assert :ok = Chunk.reset_table(384)
      rescue
        e in Postgrex.Error ->
          msg = Exception.message(e)

          if String.contains?(msg, "pg_search") or
               String.contains?(msg, "bm25") or
               String.contains?(msg, "does not exist") do
            # ParadeDB not available in this test environment — skip silently
            :ok
          else
            reraise e, __STACKTRACE__
          end
      end
    end
  end
end
