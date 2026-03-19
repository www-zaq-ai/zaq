defmodule Zaq.Engine.RouterTest do
  use ExUnit.Case, async: false

  alias Zaq.Engine.Router
  alias Zaq.Hooks.{Hook, Registry}

  # ---------------------------------------------------------------------------
  # Test hook handlers
  # ---------------------------------------------------------------------------

  defmodule SuccessHook do
    @behaviour Zaq.Hooks.Handler

    @impl true
    def handle(:before_question_dispatched, %{provider: "mattermost"} = payload, _ctx) do
      test_pid = Application.get_env(:zaq, :router_test_pid)
      send(test_pid, {:hook_called, payload.channel_id, payload.question})
      {:ok, Map.put(payload, :post_id, "post-abc")}
    end

    def handle(_event, payload, _ctx), do: {:ok, payload}
  end

  defmodule HaltingHook do
    @behaviour Zaq.Hooks.Handler

    @impl true
    def handle(:before_question_dispatched, payload, _ctx) do
      {:halt, payload}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup — isolated registry so production hooks don't interfere
  # ---------------------------------------------------------------------------

  setup do
    registry_name = :"router_test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: registry_name})
    Application.put_env(:zaq, :hooks_registry_name, registry_name)
    Application.put_env(:zaq, :router_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :hooks_registry_name)
      Application.delete_env(:zaq, :router_test_pid)
    end)

    {:ok, registry: registry_name}
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "dispatch_question/4" do
    test "calls registered sync hooks with provider, channel_id, and question in payload" do
      Registry.register(%Hook{
        handler: SuccessHook,
        events: [:before_question_dispatched],
        mode: :sync,
        node_role: :local,
        priority: 10
      })

      {:ok, _} = Router.dispatch_question("mattermost", "ch-123", "What is ZAQ?", fn _ -> :ok end)

      assert_receive {:hook_called, "ch-123", "What is ZAQ?"}
    end

    test "returns {:ok, post_id} when a hook injects :post_id into the payload" do
      Registry.register(%Hook{
        handler: SuccessHook,
        events: [:before_question_dispatched],
        mode: :sync,
        node_role: :local,
        priority: 10
      })

      assert {:ok, "post-abc"} =
               Router.dispatch_question("mattermost", "ch-123", "A question?", fn _ -> :ok end)
    end

    test "returns {:error, :dispatch_failed} when no hook sets :post_id" do
      # No hooks registered → payload passes through unchanged
      assert {:error, :dispatch_failed} =
               Router.dispatch_question("unknown", "ch-unknown", "Anyone home?", fn _ -> :ok end)
    end

    test "returns {:error, :dispatch_halted} when a hook halts the chain" do
      Registry.register(%Hook{
        handler: HaltingHook,
        events: [:before_question_dispatched],
        mode: :sync,
        node_role: :local,
        priority: 10
      })

      assert {:error, :dispatch_halted} =
               Router.dispatch_question("mattermost", "ch-fail", "Will this work?", fn _ ->
                 :ok
               end)
    end

    test "skips async hooks — only sync hooks participate in dispatch" do
      Registry.register(%Hook{
        handler: SuccessHook,
        events: [:before_question_dispatched],
        mode: :async,
        node_role: :local,
        priority: 10
      })

      # Async hook is filtered out → no :post_id injected
      assert {:error, :dispatch_failed} =
               Router.dispatch_question("mattermost", "ch-123", "What is ZAQ?", fn _ -> :ok end)

      refute_receive {:hook_called, _, _}
    end

    test "routes based on provider — hook can pattern-match on payload.provider" do
      Registry.register(%Hook{
        handler: SuccessHook,
        events: [:before_question_dispatched],
        mode: :sync,
        node_role: :local,
        priority: 10
      })

      # "mattermost" provider → SuccessHook injects post_id
      assert {:ok, "post-abc"} =
               Router.dispatch_question("mattermost", "ch-mm", "What is ZAQ?", fn _ -> :ok end)

      assert_receive {:hook_called, "ch-mm", "What is ZAQ?"}
    end
  end
end
