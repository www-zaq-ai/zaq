defmodule Zaq.Engine.Workflows.DispatchBatchTriggersRunAgentTest do
  @moduledoc """
  End-to-end concurrency spec for the **real** producer → trigger → consumer path,
  with no stub on the trigger and no shortcut into `TriggerNode`/`create_and_start_run`.

  ## Shape

  - **Workflow A** runs a `Batch` over 8 seeded items. Each item's body dispatches
    a real `lead_identified` event through the LIVE `Zaq.NodeRouter` (the production
    `DispatchEvent` tool, no injected router).
  - The real `NodeRouter.dispatch/1` broadcasts each event on the `node_router:events`
    PubSub topic. The running `Zaq.Engine.EventRegistry` matches the activated
    `"engine:lead_identified"` trigger and fires `Zaq.Engine.TriggerNode` on the
    `Zaq.TaskSupervisor` — exactly the live path. Nothing here is stubbed or short-circuited.
  - **Workflow B** is bound to that trigger and its only step is `run_agent`, so the
    8 events start 8 independent runs of B against ONE configured agent, concurrently.

  ## What it asserts

  Each run carries its `run_id` and the node's `step_index` as data on the agent
  incoming, and `Zaq.Agent.Executor.derive_scope/2` maps them to
  `"workflow:run:<run_id>:step:<step_index>"`, so every run resolves to its OWN Jido
  agent server. The test asserts all 8 runs complete, none are rejected `:busy`, and
  exactly 8 distinct `"<name>:workflow:run:<run_id>:step:0"` servers were spawned —
  i.e. every spawned agent has a different process name.

  Only the LLM HTTP edge is stubbed (the first request holds its response open to
  guarantee the 8 runs really overlap in time). Runs `async: false`: the trigger
  fan-out happens in `Task` children that need the shared Ecto sandbox, and the agent
  path runs for real.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Workflows
  alias Zaq.TestSupport.OpenAIStub

  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @dispatch_event_module "Zaq.Agent.Tools.Workflow.DispatchEvent"
  @run_agent_module "Zaq.Agent.Tools.Workflow.RunAgent"

  @event_name "lead_identified"
  @units 8

  # Seeds the fixed list the batch fans out over. One required-free schema keeps it
  # a plain producer; the batch detects its per-item delivery field from the body's
  # first action (`pass_item`), not from here.
  defmodule SeedItems do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "seed_items",
      description: "Emit eight items to fan out over.",
      schema: [
        count: [type: :integer, required: false, default: 8, doc: "How many items to emit."]
      ],
      output_schema: [
        items: [type: {:list, :map}, required: true, doc: "Items to dispatch, one event each."]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      count = Map.get(params, :count, 8)

      items =
        Enum.map(1..count, fn i ->
          %{"id" => i, "email" => "lead#{i}@example.com", "name" => "Lead #{i}"}
        end)

      {:ok, %{items: items}}
    end
  end

  # Identity step: receives one batch item under `input` and passes it through. Its
  # single required field makes the batch fan-out field unambiguous, and forwarding
  # `input` lets the downstream `DispatchEvent` send it as the event payload.
  defmodule PrepareItem do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "prepare_item",
      description: "Pass a single batch item through as `input`.",
      schema: [input: [type: :map, required: true, doc: "One item from the batch."]],
      output_schema: [input: [type: :map, required: true, doc: "The item, unchanged."]]

    @impl Jido.Action
    def run(%{input: input}, _ctx), do: {:ok, %{input: input}}
  end

  setup do
    # The workflow engine dispatches run.started/completed/failed lifecycle events
    # through the CONFIGURED node_router — Zaq.NodeRouterMock in test (config/test.exs).
    # Pass those straight through. Crucially we do NOT route anything into TriggerNode
    # here: the `lead_identified` events flow through the REAL Zaq.NodeRouter that
    # `DispatchEvent` uses by default, so the live EventRegistry → TriggerNode path
    # fires the trigger. Global so the trigger Task children inherit the stub.
    Mox.set_mox_global()
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    # The EventRegistry is not part of the test supervision tree, so start a real
    # one here. It subscribes to the `node_router:events` PubSub topic in init, and
    # `Workflows.create_trigger/1` (below) activates its event key via `sync_registry`
    # — this is the genuine routing seam, no stub and no shortcut into TriggerNode.
    start_supervised!(Zaq.Engine.EventRegistry)

    :ok
  end

  test "a batch of #{@units} dispatched events triggers #{@units} isolated run_agent servers via the real trigger path" do
    test_pid = self()

    # The first LLM request to land holds its response open, guaranteeing all runs
    # overlap in time. With per-run scope isolation this just makes one run slower;
    # with a shared scope it would force the rest into :busy.
    counter = :atomics.new(1, [])

    handler = fn conn, _body ->
      n = :atomics.add_get(counter, 1, 1)
      if n == 1, do: Process.sleep(800)
      send(test_pid, {:llm_hit, n})
      {200, streamed_reply(conn.request_path, "Yo", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Batch Trigger Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Batch Trigger Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Reply with Yo.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    # Workflow B: triggered by `lead_identified`, single run_agent step.
    {:ok, workflow_b} =
      Workflows.create_workflow(%{
        name: "Batch Trigger B #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "run_agent",
            type: "action",
            module: @run_agent_module,
            params: %{"agent_id" => configured_agent.id, "input" => "hello"},
            index: 0
          }
        ],
        edges: []
      })

    # The real trigger wiring: create_trigger normalizes the name to
    # "engine:lead_identified" and (via sync_registry) activates it in the running
    # EventRegistry, so live broadcasts of that event fire this trigger.
    {:ok, trigger} = Workflows.create_trigger(%{event_name: @event_name})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow_b)

    # Workflow A: seed 8 items, fan them out via Batch, dispatch one real event each.
    {:ok, workflow_a} = Workflows.create_workflow(workflow_a_params())

    assert {:ok, run_a} = Workflows.create_and_start_run(workflow_a, source_event())
    assert run_a.status == "completed", "producer batch should complete and dispatch 8 events"

    # The producer dispatched 8 events into the live router. The EventRegistry fires
    # them asynchronously on the TaskSupervisor, so wait for the 8 B runs to settle.
    runs = wait_for_runs(workflow_b.id, @units, 30_000)

    assert length(runs) == @units, "every dispatched event should create one run of B"

    statuses = Enum.frequencies_by(runs, & &1.status)

    assert statuses["completed"] == @units,
           "expected all #{@units} triggered runs to complete; got #{inspect(statuses)}"

    busy_failures =
      runs
      |> Enum.flat_map(&Workflows.list_step_runs(&1.id))
      |> Enum.filter(fn sr ->
        sr.status == "failed" and is_map(sr.errors) and (sr.errors["reason"] || "") =~ ":busy"
      end)

    assert busy_failures == [],
           "expected no :busy rejections, got #{length(busy_failures)}"

    # Naming proof: each run resolved to its OWN agent server, keyed on its run_id and
    # the run_agent step index (0) — exactly one distinct
    # `"<name>:workflow:run:<run_id>:step:0"` process per run.
    expected =
      runs
      |> Enum.map(&"#{configured_agent.name}:workflow:run:#{&1.id}:step:0")
      |> Enum.sort()

    assert Enum.sort(server_ids_for(configured_agent.name)) == expected
  end

  # Workflow A definition: seed_items → Batch(prepare_item, dispatch_item). The
  # dispatch step is the production DispatchEvent with no router override, so it
  # publishes through the real Zaq.NodeRouter. `machine: true` marks each triggered
  # B run as actorless (skip_permissions), mirroring the live producer.
  defp workflow_a_params do
    %{
      name: "Batch Trigger A #{System.unique_integer()}",
      status: "active",
      nodes: [
        %{
          name: "seed_items",
          type: "action",
          module: inspect(SeedItems),
          params: %{"count" => @units},
          index: 0
        },
        %{
          name: "process_items",
          type: "action",
          module: @batch_module,
          params: %{
            "delivery" => "item",
            "strategy" => "skip_and_continue",
            "batch_size" => @units,
            "process" => [
              %{
                "name" => "prepare_item",
                "type" => "action",
                "module" => inspect(PrepareItem),
                "params" => %{}
              },
              %{
                "name" => "dispatch_item",
                "type" => "action",
                "module" => @dispatch_event_module,
                "params" => %{"event_name" => @event_name, "machine" => true}
              }
            ]
          },
          index: 1
        }
      ],
      edges: [
        %{
          from: "seed_items",
          to: "process_items",
          condition: %{"field" => "items", "op" => "not_empty"},
          mapping: %{"items" => "items"}
        }
      ]
    }
  end

  defp source_event do
    %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => %{}},
      "trace_id" => Ecto.UUID.generate()
    }
  end

  # Poll until `count` runs of the workflow have settled (completed/failed) or the
  # timeout elapses — the trigger path is fully async, so there is nothing to await.
  defp wait_for_runs(workflow_id, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_runs(workflow_id, count, deadline)
  end

  defp do_wait_for_runs(workflow_id, count, deadline) do
    runs = Workflows.list_runs(workflow_id)
    settled = Enum.filter(runs, &(&1.status in ["completed", "failed"]))

    cond do
      length(settled) >= count ->
        runs

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "timed out waiting for #{count} runs: #{length(settled)} settled of #{length(runs)} total"
        )

      true ->
        Process.sleep(50)
        do_wait_for_runs(workflow_id, count, deadline)
    end
  end

  # Base server ids in the Jido agent registry, shaped "<agent_name>:<scope>". The
  # react strategy also registers "<server_id>/react_worker" children, excluded so
  # we assert on the spawned agent server itself.
  defp server_ids_for(agent_name) do
    Zaq.Agent.Jido
    |> Jido.registry_name()
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&String.contains?(&1, "/"))
    |> Enum.filter(&String.starts_with?(&1, agent_name <> ":"))
  end

  defp streamed_reply("/v1/chat/completions", text, model) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
      })

    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
      })

    "data: #{chunk}\n\ndata: #{done_chunk}\n\ndata: [DONE]\n\n"
  end

  defp streamed_reply(_path, text, model) do
    delta_event = Jason.encode!(%{"delta" => text})

    completed_event =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    [
      "event: response.output_text.delta\n",
      "data: #{delta_event}\n\n",
      "event: response.completed\n",
      "data: #{completed_event}\n\n"
    ]
    |> IO.iodata_to_binary()
  end
end
