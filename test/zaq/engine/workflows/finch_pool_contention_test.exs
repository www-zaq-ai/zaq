defmodule Zaq.Engine.Workflows.FinchPoolContentionTest do
  @moduledoc """
  Regression test for the shared ReqLLM Finch pool under concurrent workflow
  load. Forces `ReqLLM.Finch`'s pool `count` down to 8 — below the 10 real LLM
  calls this test drives (5 concurrent workflow runs x 2 agent nodes each) — so
  a checkout-timeout/pool-exhaustion regression surfaces immediately instead of
  hiding behind spare pool headroom.

  Only the LLM HTTP edge is mocked, and it is a real local Bandit server (not a
  Req.Test stub), so every request really goes through Finch. Everything else —
  workflow DAG, the `run_agent` tool, `Executor`, ReqLLM — runs for real.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Workflows
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  @pool_count 8

  setup do
    Mox.set_mox_global()
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    original_finch_config = Application.get_env(:req_llm, :finch, [])
    shrink_finch_pool(@pool_count)
    on_exit(fn -> restore_finch_pool(original_finch_config) end)

    :ok
  end

  # Swaps the live `ReqLLM.Finch` child for one with a smaller pool `count`, in
  # place, under its existing supervisor (`ReqLLM.Supervisor`). Restarting via
  # `Supervisor.restart_child/2` would just reuse the ORIGINAL childspec
  # captured when the app booted, so the child must be deleted and re-added
  # with the new pool args instead.
  # Finch derives its child-spec `id` from the `:name` option (`ReqLLM.Finch`),
  # not the bare `Finch` module — that's the id `ReqLLM.Supervisor` registered
  # it under at boot.
  defp shrink_finch_pool(count) do
    :ok = Supervisor.terminate_child(ReqLLM.Supervisor, ReqLLM.Finch)
    :ok = Supervisor.delete_child(ReqLLM.Supervisor, ReqLLM.Finch)

    {:ok, _pid} =
      Supervisor.start_child(
        ReqLLM.Supervisor,
        {Finch,
         name: ReqLLM.Finch, pools: %{default: [protocols: [:http1], size: 1, count: count]}}
      )
  end

  defp restore_finch_pool(finch_config) do
    :ok = Supervisor.terminate_child(ReqLLM.Supervisor, ReqLLM.Finch)
    :ok = Supervisor.delete_child(ReqLLM.Supervisor, ReqLLM.Finch)
    {:ok, _pid} = Supervisor.start_child(ReqLLM.Supervisor, {Finch, finch_config})
  end

  defp source_event do
    %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual"},
      "trace_id" => Ecto.UUID.generate()
    }
  end

  defp create_agent(endpoint, marker) do
    credential =
      ai_credential_fixture(%{
        name: "Pool Cred #{marker} #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Pool Agent #{marker} #{System.unique_integer([:positive])}",
        description: "",
        job: "#{marker}. Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    agent
  end

  defp build_two_agent_workflow(agent_a, agent_b) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Finch Pool WF #{System.unique_integer()}",
        status: "active",
        # A trivial "root_noop" node fans out to both agents. Neither agent
        # depends on the other's output, so once root_noop resolves, Runic
        # fires agent_a and agent_b concurrently within a single run — the
        # real source of pool pressure, on top of running 5 runs concurrently.
        # (Two fully disconnected root nodes are rejected as an invalid
        # composition, so they must share this common upstream node instead.)
        nodes: [
          %{
            name: "root_noop",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.Sleep",
            params: %{"duration_ms" => 0},
            index: 0
          },
          %{
            name: "agent_a",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{"agent_id" => agent_a.id, "input" => "hello a"},
            index: 1
          },
          %{
            name: "agent_b",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{"agent_id" => agent_b.id, "input" => "hello b"},
            index: 2
          }
        ],
        edges: [
          %{from: "root_noop", to: "agent_a"},
          %{from: "root_noop", to: "agent_b"}
        ]
      })

    workflow
  end

  defp pool_error?(nil), do: false

  defp pool_error?(errors) do
    errors
    |> inspect()
    |> String.downcase()
    |> String.contains?(["pool_timeout", "checkout", "nimblepool"])
  end

  test "5 concurrent runs of a 2-agent workflow complete cleanly on an 8-slot Finch pool" do
    test_pid = self()
    hits = :atomics.new(1, [])

    handler = fn conn, body ->
      :atomics.add_get(hits, 1, 1)
      send(test_pid, {:llm_hit, conn.request_path})
      # Hold each connection open for a random, realistic processing time so
      # overlapping requests genuinely contend for the shrunk pool instead of
      # completing before they collide.
      Process.sleep(Enum.random(100..500))

      model = MultiAgentOpenAIStub.request_model(body) || "gpt-4.1-mini"
      {200, MultiAgentOpenAIStub.text_sse("ok", model)}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    agent_a = create_agent(endpoint, "MARKER_A")
    agent_b = create_agent(endpoint, "MARKER_B")

    on_exit(fn ->
      _ = ServerManager.stop_server(agent_a)
      _ = ServerManager.stop_server(agent_b)
    end)

    workflow = build_two_agent_workflow(agent_a, agent_b)

    # Staggered starts (real traffic never lands perfectly synchronized): run 1
    # at 1ms, run 2 at 20ms, run 3 at 25ms, run 4 at 26ms, run 5 at 30ms. The
    # whole spread (29ms) is still tiny next to each request's 100-500ms hold
    # time, so all 10 LLM calls still land close enough together to contend
    # for the 8-slot pool.
    start_delays_ms = [1, 20, 25, 26, 30]

    runs =
      start_delays_ms
      |> Enum.map(fn delay_ms ->
        Task.async(fn ->
          Process.sleep(delay_ms)
          Workflows.create_and_start_run(workflow, source_event())
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.all?(runs, &match?({:ok, %{status: "completed"}}, &1)),
           "expected every run to complete cleanly; got: #{inspect(runs)}"

    # 5 runs x 2 agents = 10 real LLM calls landed on the stub — proof the pool
    # actually served more concurrent requests than its 8-slot capacity.
    assert :atomics.get(hits, 1) == 10

    for {:ok, run} <- runs do
      step_runs = Workflows.list_step_runs(run.id)
      assert Enum.all?(step_runs, &(&1.status == "completed"))
      refute Enum.any?(step_runs, &pool_error?(&1.errors))
    end
  end
end
