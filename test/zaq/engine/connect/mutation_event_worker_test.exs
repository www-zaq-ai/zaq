defmodule Zaq.Engine.Connect.MutationEventWorkerTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  import ExUnit.CaptureLog
  alias Zaq.Agent.Events
  alias Zaq.Engine.Connect.{MutationEvents, MutationEventWorker}

  setup :verify_on_exit!

  defp payload do
    %{
      "version" => 1,
      "event_id" => Ecto.UUID.generate(),
      "credential_id" => 1,
      "grant_id" => 2,
      "owner_type" => "person",
      "owner_id" => 3,
      "kind" => "grant_replaced",
      "occurred_at" => "2026-09-14T00:00:00Z"
    }
  end

  test "retry and duplicate attempts dispatch the same secret-free synchronous event" do
    args = payload()

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn event ->
      assert event.request == args
      assert event.next_hop.destination == :agent
      assert event.next_hop.type == :sync
      assert event.opts == [action: :connect_credential_mutated]
      assert event.actor == nil
      %{event | response: :ok}
    end)

    assert :ok = MutationEvents.deliver(args, node_router: Zaq.NodeRouterMock)
    assert :ok = MutationEvents.deliver(args, node_router: Zaq.NodeRouterMock)
  end

  test "only explicit :ok counts as delivery and failures never retain provider payloads" do
    for response <- [
          nil,
          {:ok, "SECRET"},
          {:error, {:unsupported_action, :connect_credential_mutated}},
          {:error, {:service_unavailable, :agent}},
          {:error, {:rpc_failed, :node, "SECRET"}},
          "SECRET"
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: response} end)

      log =
        capture_log(fn ->
          assert {:error, :mutation_event_delivery_failed} =
                   MutationEvents.deliver(payload(), node_router: Zaq.NodeRouterMock)
        end)

      refute log =~ "SECRET"
    end

    for failure <- [fn -> raise "SECRET" end, fn -> exit("SECRET") end, fn -> throw("SECRET") end] do
      expect(Zaq.NodeRouterMock, :dispatch, fn _ -> failure.() end)

      refute capture_log(fn ->
               assert {:error, :mutation_event_delivery_failed} =
                        MutationEvents.deliver(payload(), node_router: Zaq.NodeRouterMock)
             end) =~ "SECRET"
    end
  end

  test "default routing reaches actual unsupported Agent action and workflow stream contains only safe payload" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    args = payload()
    event = Events.build_and_dispatch_invoke_event(args, :connect_credential_mutated)
    assert event.response == {:error, {:unsupported_action, :connect_credential_mutated}}
    assert {:error, :mutation_event_delivery_failed} = perform_job(MutationEventWorker, args)
    assert_receive {:node_router_event, %{request: ^args}}
  end

  test "malformed or secret-extended jobs reject before routing" do
    for bad <- [
          nil,
          %{},
          Map.put(payload(), "version", 2),
          Map.put(payload(), "event_id", "SECRET"),
          Map.put(payload(), "credential_id", "SECRET"),
          Map.put(payload(), "owner_id", "SECRET"),
          Map.put(payload(), "kind", "SECRET"),
          Map.put(payload(), "occurred_at", "SECRET"),
          Map.put(payload(), "metadata", %{token: "SECRET"})
        ] do
      assert {:error, :invalid_mutation_event} = MutationEvents.validate(bad)

      assert {:error, :invalid_mutation_event} =
               MutationEvents.deliver(bad, node_router: Zaq.NodeRouterMock)
    end
  end

  test "real Oban retries retain UUID and eventually retain a discarded job with safe errors" do
    args = payload()
    queue = "connect-test-#{Ecto.UUID.generate()}"
    {:ok, job} = args |> MutationEventWorker.new(queue: queue) |> Oban.insert()

    for attempt <- 1..3 do
      drained = Oban.drain_queue(queue: queue, with_scheduled: true)
      assert drained.failure == if(attempt == 3, do: 0, else: 1)
      assert drained.discard == if(attempt == 3, do: 1, else: 0)

      current = Repo.reload!(job)
      assert current.attempt == attempt
      assert current.args == args
      assert current.state == if(attempt == 3, do: "discarded", else: "retryable")
      assert length(current.errors) == attempt

      assert Enum.all?(
               current.errors,
               &String.contains?(&1["error"], "mutation_event_delivery_failed")
             )
    end
  end
end
