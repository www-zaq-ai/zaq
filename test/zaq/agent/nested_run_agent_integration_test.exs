defmodule Zaq.Agent.NestedRunAgentIntegrationTest do
  @moduledoc """
  Integration tests T1 & T2 from the run_agent per-execution plan: `run_agent`
  must work as an **LLM tool call inside another agent** — Agent X's LLM decides
  to call `run_agent(Y)` to get an answer — from BOTH a workflow origin (T1) and
  a channel-message origin (T2).

  Chain per test: parent X runs → X's LLM emits a `run_agent` tool call → the
  RunAgent tool dispatches to Agent Y (real NodeRouter) → Y answers → the answer
  returns to X as the tool result → X produces its final answer. Only the LLM
  HTTP edge is mocked; both agents share one stub that branches on the
  system-prompt marker and on whether a tool result is being fed back.

  RED until `run_agent` is registered as a tool (G1) and builds its incoming from
  the tool-call context (G4).
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Workflows
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  setup do
    # Workflow lifecycle events (T1) dispatch through Zaq.NodeRouterMock in test;
    # the agent path uses the real router. Make the stub global so any process in
    # the chain sees it.
    Mox.set_mox_global()
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  # X's LLM: first turn → call run_agent(Y); after the tool result → final text.
  # Y's LLM: answer. `y_id_ref` is an :atomics cell filled once Y exists, so one
  # stub can be started before the agents are created.
  defp nested_handler(test_pid, y_id_ref) do
    fn _conn, body ->
      send(test_pid, {:llm_request, body})

      sse =
        cond do
          body =~ "MARKER_AGENT_Y" ->
            MultiAgentOpenAIStub.text_sse("ANSWER_FROM_Y", "gpt-4.1-mini")

          MultiAgentOpenAIStub.tool_result?(body) ->
            MultiAgentOpenAIStub.text_sse("X_FINAL_OK", "gpt-4.1-mini")

          true ->
            MultiAgentOpenAIStub.tool_call_sse(
              "run_agent",
              %{agent_id: :atomics.get(y_id_ref, 1), input: "ask Y"},
              model: "gpt-4.1-mini"
            )
        end

      {200, sse}
    end
  end

  # X's LLM calls run_agent(Y) WITH a `context` argument on the first turn, then
  # returns a final answer once the tool result comes back. Y never runs — the
  # CaptureIncomingRouter intercepts the run_agent dispatch — so no MARKER_AGENT_Y
  # branch is needed.
  defp context_tool_call_handler(test_pid, y_id_ref) do
    fn _conn, body ->
      send(test_pid, {:llm_request, body})

      sse =
        if MultiAgentOpenAIStub.tool_result?(body) do
          MultiAgentOpenAIStub.text_sse("X_FINAL_OK", "gpt-4.1-mini")
        else
          MultiAgentOpenAIStub.tool_call_sse(
            "run_agent",
            %{
              agent_id: :atomics.get(y_id_ref, 1),
              input: "ask Y",
              context: [
                %{type: "user_message", content: "earlier user turn"},
                %{
                  type: "tool_result",
                  content: "earlier tool output",
                  tool_call_id: "t1",
                  name: "lookup"
                }
              ]
            },
            model: "gpt-4.1-mini"
          )
        end

      {200, sse}
    end
  end

  defp create_x_and_y(endpoint) do
    credential =
      ai_credential_fixture(%{
        name: "Nested Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent_y} =
      Agent.create_agent(%{
        name: "Nested Y #{System.unique_integer([:positive])}",
        description: "",
        job: "MARKER_AGENT_Y. Answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    {:ok, agent_x} =
      Agent.create_agent(%{
        name: "Nested X #{System.unique_integer([:positive])}",
        description: "",
        job: "MARKER_AGENT_X. Use the run_agent tool to consult agent Y, then answer.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["workflow.run_agent"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    {agent_x, agent_y}
  end

  defp setup_nested(test_pid) do
    y_id_ref = :atomics.new(1, [])
    {child_spec, endpoint} = OpenAIStub.server(nested_handler(test_pid, y_id_ref), test_pid)
    start_supervised!(child_spec)

    {agent_x, agent_y} = create_x_and_y(endpoint)
    :atomics.put(y_id_ref, 1, agent_y.id)

    on_exit(fn ->
      _ = ServerManager.stop_server(agent_x)
      _ = ServerManager.stop_server(agent_y)
    end)

    {agent_x, agent_y}
  end

  defp source_event do
    %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual"},
      "trace_id" => Ecto.UUID.generate()
    }
  end

  defp drain_llm_bodies(acc) do
    receive do
      {:llm_request, body} -> drain_llm_bodies([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Base server ids registered in the Jido agent registry, each shaped
  # "<agent_name>:<scope>". The react strategy also registers internal worker
  # children under "<server_id>/react_worker"; those are excluded so we assert on
  # the spawned agent server itself.
  defp spawned_server_ids do
    Zaq.Agent.Jido
    |> Jido.registry_name()
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&String.contains?(&1, "/"))
  end

  defp server_ids_for(agent_name) do
    Enum.filter(spawned_server_ids(), &String.starts_with?(&1, agent_name <> ":"))
  end

  # Captures the %Incoming{} a `run_agent` dispatch carries (the `:run_pipeline`
  # event), and returns a canned %Outgoing{} so the caller completes without a live
  # target agent. Every other event (typing, status, the parent agent's own hops) is
  # delegated to the real router so the surrounding flow behaves normally. The target
  # pid comes from app env so it works regardless of which process dispatches.
  defmodule CaptureIncomingRouter do
    @moduledoc false
    alias Zaq.Engine.Messages.{Incoming, Outgoing}

    def dispatch(%Zaq.Event{request: %Incoming{} = incoming, opts: opts} = event) do
      if Keyword.get(opts, :action) == :run_pipeline do
        pid = Application.get_env(:zaq, :run_agent_capture_pid)
        if is_pid(pid), do: send(pid, {:captured_incoming, incoming})

        %{
          event
          | response: %Outgoing{body: "captured", channel_id: incoming.channel_id, provider: nil}
        }
      else
        Zaq.NodeRouter.dispatch(event)
      end
    end

    def dispatch(%Zaq.Event{} = event), do: Zaq.NodeRouter.dispatch(event)
  end

  # Carrier-only (Issue 1): the `context` param must survive the REAL workflow seam
  # — schema validation of a `{:list, :map}` param, the JSONB round-trip, and
  # StepRunner — and land normalised on `incoming.metadata[:context_messages]`.
  # Feeding those turns to the LLM is Issue 2, so we intercept at the node router
  # instead of running a live agent.
  test "T1 carrier: run_agent node delivers normalised context turns onto the dispatched incoming" do
    Application.put_env(:zaq, :run_agent_node_router_module, CaptureIncomingRouter)
    Application.put_env(:zaq, :run_agent_capture_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :run_agent_node_router_module)
      Application.delete_env(:zaq, :run_agent_capture_pid)
    end)

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Ctx Carrier WF #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "run_agent",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{
              "agent_id" => 4242,
              "input" => "hello {{who}}",
              "who" => "world",
              # String-keyed, all three roles + optional fields — the JSONB shape.
              "context" => [
                %{"type" => "user_message", "content" => "earlier question about {{who}}"},
                %{"type" => "assistant_message", "content" => "earlier answer"},
                %{
                  "type" => "tool_result",
                  "content" => "42",
                  "tool_call_id" => "c1",
                  "name" => "calc"
                },
                %{"type" => "system_message", "content" => "should be dropped"}
              ]
            },
            index: 0
          }
        ],
        edges: []
      })

    assert {:ok, run} = Workflows.create_and_start_run(workflow, source_event())
    assert run.status == "completed"

    assert_received {:captured_incoming, %Incoming{} = incoming}

    # Unknown-type entry dropped; the three valid turns are normalised in order,
    # with {{variable}} substitution applied to content.
    assert [
             %{type: "user_message", content: "earlier question about world"},
             %{type: "assistant_message", content: "earlier answer"},
             %{type: "tool_result", content: "42", tool_call_id: "c1", name: "calc"}
           ] = incoming.metadata[:context_messages]

    # The run's own user message is still substituted independently of the turns.
    assert incoming.content == "hello world"
  end

  test "T1: workflow → agent(X) → tool call run_agent(Y)" do
    {agent_x, agent_y} = setup_nested(self())

    {:ok, workflow_b} =
      Workflows.create_workflow(%{
        name: "Nested WF #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "run_agent",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{"agent_id" => agent_x.id, "input" => "hello"},
            index: 0
          }
        ],
        edges: []
      })

    assert {:ok, run} = Workflows.create_and_start_run(workflow_b, source_event())
    assert run.status == "completed"

    [step] = Workflows.list_step_runs(run.id)
    assert step.status == "completed"
    assert inspect(step.results) =~ "X_FINAL_OK"

    bodies = drain_llm_bodies([])
    assert Enum.any?(bodies, &(&1 =~ "MARKER_AGENT_Y")), "agent Y must run via the run_agent tool"
    assert Enum.any?(bodies, &(&1 =~ "ANSWER_FROM_Y")), "Y's answer must feed back to X"

    # Parent X and nested Y are spawned as DISTINCT Jido servers — if their
    # server ids (`<name>:<scope>`) collided, one run would reject the other as
    # `:busy`. X is the workflow node, scoped per run and step (`run_agent` is
    # the index-0 node); Y is a different agent name reached via the tool call.
    assert [x_server] = server_ids_for(agent_x.name)
    assert [y_server] = server_ids_for(agent_y.name)
    assert x_server == "#{agent_x.name}:workflow:run:#{run.id}:step:0"
    assert x_server != y_server
  end

  test "T2: channel message → agent(X) → tool call run_agent(Y)" do
    {agent_x, agent_y} = setup_nested(self())

    # A channel-origin incoming (provider + person). The channel bridge ultimately
    # routes to Executor.run via :run_pipeline; we drive that directly so the
    # %Outgoing{} is returned instead of delivered through a channel return-hop.
    incoming = %Incoming{
      content: "consult Y for me",
      channel_id: "chan-1",
      provider: :web,
      person: %{id: 7}
    }

    outgoing = Executor.run(incoming, agent_id: to_string(agent_x.id))

    assert outgoing.metadata.error == false
    assert outgoing.body =~ "X_FINAL_OK"

    bodies = drain_llm_bodies([])
    assert Enum.any?(bodies, &(&1 =~ "MARKER_AGENT_Y")), "agent Y must run via the run_agent tool"
    assert Enum.any?(bodies, &(&1 =~ "ANSWER_FROM_Y")), "Y's answer must feed back to X"

    # X (channel-scoped to the person) and Y (reached via the tool call) are
    # distinct spawned servers — different names, so they cannot collide.
    assert [x_server] = server_ids_for(agent_x.name)
    assert [y_server] = server_ids_for(agent_y.name)
    assert x_server == "#{agent_x.name}:bo:person:7"
    assert x_server != y_server
  end

  # Carrier through the agent-tool-call seam (Issue 1): when Agent X's LLM calls
  # `run_agent(Y)` WITH a `context` argument, those turns must be normalised and
  # carried onto the %Incoming{} dispatched to Y. We intercept the run_agent
  # dispatch (Y never runs) and assert Y's incoming metadata; consuming the turns
  # is Issue 2.
  test "T2 carrier: agent(X)'s run_agent tool call carries context onto agent(Y)'s incoming" do
    y_id_ref = :atomics.new(1, [])

    {child_spec, endpoint} =
      OpenAIStub.server(context_tool_call_handler(self(), y_id_ref), self())

    start_supervised!(child_spec)

    {agent_x, agent_y} = create_x_and_y(endpoint)
    :atomics.put(y_id_ref, 1, agent_y.id)

    on_exit(fn ->
      _ = ServerManager.stop_server(agent_x)
      _ = ServerManager.stop_server(agent_y)
    end)

    Application.put_env(:zaq, :run_agent_capture_pid, self())
    on_exit(fn -> Application.delete_env(:zaq, :run_agent_capture_pid) end)

    incoming = %Incoming{
      content: "consult Y for me",
      channel_id: "chan-1",
      provider: :web,
      person: %{id: 7}
    }

    # Route X's run through the capture router so the nested run_agent(Y) dispatch is
    # intercepted; every other hop (typing/status) is delegated to the real router.
    outgoing =
      Executor.run(incoming, agent_id: to_string(agent_x.id), node_router: CaptureIncomingRouter)

    assert outgoing.metadata.error == false
    assert outgoing.body =~ "X_FINAL_OK"

    assert_received {:captured_incoming, %Incoming{} = y_incoming}

    assert [
             %{type: "user_message", content: "earlier user turn"},
             %{
               type: "tool_result",
               content: "earlier tool output",
               tool_call_id: "t1",
               name: "lookup"
             }
           ] = y_incoming.metadata[:context_messages]
  end
end
