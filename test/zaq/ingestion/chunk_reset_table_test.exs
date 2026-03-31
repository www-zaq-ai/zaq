defmodule Zaq.Ingestion.ChunkResetTableTest do
  # async: false — reset_table does DDL (DROP/CREATE TABLE) that would race
  # with other async tests sharing the same schema.
  use Zaq.DataCase, async: false

  alias Zaq.Hooks.{Hook, Registry}
  alias Zaq.Ingestion.Chunk

  # Captures :after_embedding_reset dispatches by forwarding to the test
  # process stored in a shared ETS table.
  defmodule ResetHookTestHandler do
    @behaviour Zaq.Hooks.Handler

    @impl true
    def handle(:after_embedding_reset, payload, _ctx) do
      case :ets.lookup(:chunk_reset_hook_captures, :receiver) do
        [{:receiver, pid}] -> send(pid, {:after_embedding_reset, payload})
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
      events: [:after_embedding_reset],
      mode: :async
    })

    on_exit(fn -> Application.delete_env(:zaq, :hooks_registry_name) end)

    :ok
  end

  describe "reset_table/1" do
    test "recreates the chunks table with the new dimension" do
      assert :ok = Chunk.reset_table(384)
    end

    test "dispatches :after_embedding_reset with new_dimension in payload" do
      Chunk.reset_table(512)
      assert_receive {:after_embedding_reset, %{new_dimension: 512}}, 1000
    end
  end
end
