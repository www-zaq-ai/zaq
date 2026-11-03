defmodule Zaq.Agent.ToolStepsIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, ServerManager, StreamEvents}
  alias Zaq.Channels.Api, as: ChannelsApi
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.TestSupport.{BudgetProbeTool, IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}

  defmodule RecordingRouter do
    def dispatch(event) do
      send(event.request.metadata.session_id, {:step_upsert, event.request})

      %{event | response: {:ok, %{message_id: "status"}}}
    end
  end

  defmodule DeliveryBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(outgoing, _details) do
      send(outgoing.metadata.session_id, {:final_tool_publication, outgoing})
      :ok
    end
  end

  test "native worker exit leaves batch outcomes unknown even when one tool actually finished" do
    owner = self()

    handler = fn _conn, _body ->
      first =
        MultiAgentOpenAIStub.tool_call_sse("budget_probe", %{value: "a"},
          call_id: "call_a",
          fc_id: "fc_a"
        )

      second =
        MultiAgentOpenAIStub.tool_call_sse("budget_probe", %{value: "b"},
          call_id: "call_b",
          fc_id: "fc_b"
        )

      [prefix, _completed] = String.split(first, "event: response.completed", parts: 2)
      {200, prefix <> String.replace(second, "\"output_index\":0", "\"output_index\":1")}
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(child)
    scope = "steps-#{Ecto.UUID.generate()}"
    configured = IntegrationAgent.create!(endpoint, scope, "Use the probe tools.", [])

    assert {:ok, server} =
             ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
               actor: %{kind: :system, subject: "tool-steps-test"}
             )

    assert {:ok, _} = Jido.AI.register_tool(server, BudgetProbeTool)

    incoming = %Incoming{
      content: "Use both probes",
      channel_id: "bo",
      provider: :web,
      metadata: %{session_id: owner, request_id: "root", assistant_message_id: "answer"}
    }

    consumer =
      Task.async(fn ->
        assert {:ok, %{request: request, events: events}} =
                 Factory.ask_with_config(server, "Use both probes", configured,
                   tool_context: %{test_pid: owner}
                 )

        events =
          Stream.map(events, fn event ->
            send(owner, {:native_tool_event, event.kind})
            event
          end)

        StreamEvents.consume(events, incoming, request: request, node_router: RecordingRouter)
      end)

    assert_receive {:budget_probe_started, first_tool, "a"}, 5_000
    assert_receive {:budget_probe_started, second_tool, "b"}, 5_000
    on_exit(fn -> send(second_tool, :release) end)

    # Tool processes can start before their native events reach the consumer.
    # Establish the recorded batch before injecting the worker exit whose
    # settlement this test exercises.
    assert_receive {:native_tool_event, :tool_started}, 5_000
    assert_receive {:native_tool_event, :tool_started}, 5_000

    first_monitor = Process.monitor(first_tool)
    send(first_tool, :release)
    assert_receive {:DOWN, ^first_monitor, :process, ^first_tool, :normal}, 5_000

    assert {:ok, status} = Jido.AgentServer.status(server)
    worker = status.raw_state.__strategy__.react_worker_pid
    assert is_pid(worker)
    Process.exit(worker, :kill)

    assert {:error, {:react_worker_exit, :killed}, result} = Task.await(consumer, 10_000)

    assert [
             %{"id" => "call_a", "state" => "unknown", "sequence" => 1},
             %{"id" => "call_b", "state" => "unknown", "sequence" => 2}
           ] = ToolStep.project(result.tool_calls)

    refute Map.has_key?(result, :tool_steps)
    refute Map.has_key?(result.incoming.metadata, :tool_steps)

    assert_receive {:native_tool_event, :request_failed}
    refute_received {:native_tool_event, :tool_completed}
    # Settled facts are guaranteed in final delivery, not in an intermediate
    # update. Any earlier publication still uses the correlated safe projection.
    for upsert <- collect_upserts([]) do
      assert upsert.metadata.assistant_message_id == "answer"
      assert upsert.metadata.request_id == "root"
      refute Jason.encode!(upsert.metadata.tool_steps) =~ "arguments"
    end

    internal_result =
      result
      |> Map.take([:tool_calls, :trace, :measurements])
      |> Map.put(:answer, "Request failed")

    outgoing = Outgoing.from_pipeline_result(result.incoming, internal_result)

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, bridge_module: DeliveryBridge]
      )

    delivered = ChannelsApi.handle_event(event, :deliver_outgoing, nil)
    assert delivered.response == {:ok, %{}}
    assert_receive {:final_tool_publication, published}
    assert published.metadata.tool_steps == ToolStep.project(result.tool_calls)
    assert published.metadata.assistant_message_id == "answer"
    assert published.metadata.request_id == "root"
    assert delivered.request.metadata.tool_calls == result.tool_calls
    refute Map.has_key?(delivered.request.metadata, :tool_steps)
    refute Jason.encode!(published.metadata.tool_steps) =~ "arguments"
  end

  defp collect_upserts(acc) do
    receive do
      {:step_upsert, outgoing} -> collect_upserts([outgoing | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
