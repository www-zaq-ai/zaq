defmodule Zaq.Agent.RequestEffectsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.{Factory, RequestEffects}

  defmodule Labels do
    use Jido.Action,
      name: "collect_private_labels",
      description: "Test private request labels",
      schema: Zoi.object(%{label: Zoi.string()})

    @behaviour RequestEffects
    @impl Jido.Action
    def run(%{label: label}, context) do
      with {:ok, effect} <- RequestEffects.command(context, __MODULE__, label) do
        {:ok, %{accepted: true}, [effect]}
      end
    end

    @impl RequestEffects
    def init_request_effect, do: []
    @impl RequestEffects
    def reduce_request_effect(labels, label), do: {:ok, labels ++ [label]}
  end

  defmodule Counter do
    use Jido.Action,
      name: "count_private_items",
      description: "Test independent private request count",
      schema: Zoi.object(%{amount: Zoi.integer()})

    @behaviour RequestEffects
    @impl Jido.Action
    def run(%{amount: amount}, context) do
      with {:ok, effect} <- RequestEffects.command(context, __MODULE__, amount) do
        {:ok, %{accepted: true}, [effect]}
      end
    end

    @impl RequestEffects
    def init_request_effect, do: 0
    @impl RequestEffects
    def reduce_request_effect(count, amount) when amount >= 0, do: {:ok, count + amount}
    def reduce_request_effect(_count, _amount), do: {:error, :negative_amount}
  end

  test "independent Actions share lifecycle without sharing values, and rejected effects leave state intact" do
    effects = RequestEffects.new("r", self(), [Labels, Counter])
    label = command(effects, Labels, "private-label", "label-call")
    count = command(effects, Counter, 3, "count-call")
    assert {:ok, effects} = RequestEffects.apply_command(effects, label)
    assert {:ok, effects} = RequestEffects.apply_command(effects, count)
    assert effects.values == %{Labels => ["private-label"], Counter => 3}
    assert {:ok, ^effects} = RequestEffects.apply_command(effects, label)

    assert {:error, :negative_amount} =
             RequestEffects.apply_command(effects, %{
               count
               | invocation_id: "negative",
                 payload: -1
             })

    assert RequestEffects.finish(effects, :failed).values == %{Labels => [], Counter => 0}

    assert {:error, _} =
             RequestEffects.command(
               %{request_id: "r", state: %{request_effects: effects}},
               Factory,
               "unregistered"
             )
  end

  test "a tool cannot apply another registered handler's command" do
    effects = RequestEffects.new("r", self(), [Labels, Counter])
    cmd = command(effects, Counter, 9, "forged-call")
    {:ok, agent} = Jido.Agent.new(id: "effects-test", state: %{request_effects: effects})

    event = %{
      kind: :tool_completed,
      request_id: "r",
      seq: 1,
      tool_name: Labels.name(),
      data: %{
        result: {:ok, %{}, [%Jido.Agent.StateOp.SetPath{path: [:request_effect], value: cmd}]}
      }
    }

    assert {:ok, agent, redacted} = RequestEffects.accept_event(agent, event)
    assert agent.state.request_effects.values == effects.values
    assert {:error, :effect_rejected, []} = redacted.data.result
    refute inspect(redacted) =~ "forged-call"
  end

  test "a rejected reducer command preserves values and redacts its private failure" do
    effects = RequestEffects.new("r", self(), [Counter])

    assert {:ok, effects} =
             RequestEffects.apply_command(effects, command(effects, Counter, 3, "accepted-call"))

    rejected = command(effects, Counter, -9, "private-rejected-call")
    {:ok, agent} = Jido.Agent.new(id: "rejected-effect", state: %{request_effects: effects})

    event = %{
      kind: :tool_completed,
      request_id: "r",
      seq: 1,
      tool_name: Counter.name(),
      data: %{
        arguments: %{amount: -9},
        result:
          {:ok, %{}, [%Jido.Agent.StateOp.SetPath{path: [:request_effect], value: rejected}]}
      }
    }

    assert {:ok, agent, redacted} = RequestEffects.accept_event(agent, event)
    assert agent.state.request_effects.values == effects.values
    assert agent.state.request_effects.seen == effects.seen
    assert redacted.data.arguments == %{}
    assert redacted.data.result == {:error, :effect_rejected, []}
    refute inspect(redacted) =~ "negative_amount"
    refute inspect(redacted) =~ "private-rejected-call"
  end

  test "completion without a stream sink freezes values without publishing a snapshot" do
    effects = RequestEffects.new("r", self(), [Counter])

    assert {:ok, effects} =
             RequestEffects.apply_command(effects, command(effects, Counter, 4, "count-call"))

    {:ok, agent} =
      Jido.Agent.new(
        id: "effect-without-sink",
        state: %{request_effects: effects, requests: %{"r" => %{status: :running}}}
      )

    event = %{kind: :request_completed, request_id: "r", seq: 1, data: %{result: "Done."}}
    assert {:ok, agent, ^event} = RequestEffects.accept_event(agent, event)
    assert agent.state.request_effects.status == :completed
    assert agent.state.request_effects.values == %{Counter => 4}
    refute_received {RequestEffects, "r", _, _}
    assert :stale = RequestEffects.accept_event(agent, %{event | seq: 2})
  end

  defp command(effects, handler, payload, call) do
    {:ok, effect} =
      RequestEffects.command(
        %{request_id: effects.request_id, state: %{request_effects: effects}},
        handler,
        payload
      )

    {:ok, _, [effect]} =
      RequestEffects.bind_invocation(%{action_module: handler, id: call}, {:ok, %{}, [effect]})

    effect.value
  end
end

defmodule Zaq.Agent.RequestEffectsRuntimeTest do
  # ServerManager resolves credentials outside the test process and needs the shared sandbox.
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, RequestEffects, ServerManager}
  alias Zaq.Agent.RequestEffectsTest.{Counter, Labels}
  alias Zaq.TestSupport.{IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}

  test "real Factory supports non-attachment handlers and hands off private, fresh per-request results" do
    secret = "private-label-must-not-enter-traces"

    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             {Labels.name(), %{label: secret}},
             {Counter.name(), %{amount: 7}},
             :done,
             {Counter.name(), %{amount: 7}},
             :done
           ]
         end}
      )

    {child, endpoint} =
      OpenAIStub.server(
        fn _conn, _body ->
          step = Agent.get_and_update(script, fn [step | rest] -> {step, rest} end)

          response =
            case step do
              :done ->
                MultiAgentOpenAIStub.text_sse("Done.", "gpt-4.1-mini")

              {name, arguments} ->
                MultiAgentOpenAIStub.tool_call_sse(name, arguments,
                  model: "gpt-4.1-mini",
                  call_id: Ecto.UUID.generate()
                )
            end

          {200, response}
        end,
        self()
      )

    start_supervised!(child)
    scope = "generic-effects-#{Ecto.UUID.generate()}"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the requested test tool.", [])

    {:ok, server} =
      ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
        actor: %{kind: :system, subject: "effects-test"}
      )

    assert {:ok, _} = Jido.AI.register_tool(server, Labels)
    assert {:ok, _} = Jido.AI.register_tool(server, Counter)
    pid = GenServer.whereis(server)

    for {query, expected} <- [
          {"labels and count", %{Labels => [secret], Counter => 7}},
          {"count", %{Labels => [], Counter => 7}}
        ] do
      assert {:ok, %{request: request, events: events}} =
               Factory.ask_with_config(server, query, configured)

      observed = Enum.to_list(events)
      assert List.last(observed).kind == :request_completed
      assert RequestEffects.take_snapshot(request.id, pid) == expected
      assert RequestEffects.take_snapshot(request.id, pid) == %{}
      assert {:ok, status} = Jido.AgentServer.status(server)
      assert status.raw_state.request_effects.values == expected

      refute inspect({observed, status.raw_state.__strategy__.request_traces}, limit: :infinity) =~
               secret
    end

    assert Agent.get(script, & &1) == []
  end
end

defmodule Zaq.Agent.RequestEffectCharacterizationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, ServerManager}
  alias Zaq.TestSupport.{IntegrationAgent, RequestEffectProbe, ToolCallingLLMStub}

  test "native request identity reaches validated tools and effects reach the owning Jido state" do
    routes = [
      %{
        match: fn _ -> true end,
        tool: "request_effect_probe",
        arguments: fn _ -> %{value: "accepted"} end
      }
    ]

    {child, endpoint} = ToolCallingLLMStub.server(routes, final_response: "Done.")
    start_supervised!(child)
    scope = "effect-#{Ecto.UUID.generate()}"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the probe.", [])

    {:ok, server} =
      ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
        actor: %{kind: :system, subject: "effect-test"}
      )

    assert {:ok, _} = Jido.AI.register_tool(server, RequestEffectProbe)

    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(server, "Probe", configured,
               tool_context: %{test_pid: self()}
             )

    observed = Enum.to_list(events)
    assert_receive {:request_effect_context, context}, 5_000
    assert context.request_id == request.id
    assert context.run_id == request.id
    assert context.agent_module == Factory
    assert is_map(context.state)
    assert is_binary(context.execution_root)

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effect_probe == "accepted"

    completed = Enum.find(observed, &(&1.kind == :tool_completed))
    assert {:ok, _, [%Jido.Agent.StateOp.SetPath{}]} = completed.data.result
    assert List.last(observed).kind == :request_completed
    refute_received {:llm_stub_error, _}
  end
end
