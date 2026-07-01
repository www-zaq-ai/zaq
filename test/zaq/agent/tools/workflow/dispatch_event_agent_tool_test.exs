defmodule Zaq.Agent.Tools.Workflow.DispatchEventAgentToolTest do
  @moduledoc """
  Drives `DispatchEvent` end-to-end as an agent tool: a real `react` agent is
  created with `enabled_tool_keys: ["workflow.dispatch_event"]`, the LLM (stubbed
  via `OpenAIStub`) emits a tool call for `dispatch_event`, and the agent pipeline
  executes the tool. The `node_router` injected into the tool context (exactly as
  `Zaq.Agent.Executor` injects the live `Zaq.NodeRouter`) captures the dispatched
  event, proving it reached the engine.

  `async: false` because `OpenAIStub` binds an ephemeral HTTP port and the tool
  runs in a task under `Jido.Action.TaskSupervisor`; the capturing router is a
  module, so it forwards to a registered observer process.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.TestSupport.OpenAIStub

  @observer :dispatch_event_agent_observer

  # Captures every event the pipeline dispatches through the injected node_router
  # (the dispatch_event tool's engine event, plus typing/status events). A module
  # can't close over the test pid, so it forwards to a registered observer.
  defmodule CaptureRouter do
    def dispatch(event) do
      pid = Process.whereis(:dispatch_event_agent_observer) || self()
      send(pid, {:dispatched, event})
      # async dispatch → nil response; DispatchEvent treats nil as success.
      event
    end
  end

  # Skips the real status/typing broadcast machinery — not under test here.
  defmodule StubStatus do
    def broadcast(incoming, _stage, _message, _node_router), do: incoming
    def broadcast(incoming, _stage, _message, _node_router, _opts), do: incoming
  end

  setup do
    Process.register(self(), @observer)
    :ok
  end

  test "workflow.dispatch_event is whitelisted and resolves to the tool module" do
    assert Registry.valid_tool_key?("workflow.dispatch_event")

    assert {:ok, [Zaq.Agent.Tools.Workflow.DispatchEvent]} =
             Registry.resolve_modules(["workflow.dispatch_event"])
  end

  test "an agent calls the dispatch_event tool and the event reaches the engine" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)

      # The follow-up request carries the tool's output; answer with final text.
      has_tool_output =
        body =~ "function_call_output" or
          Enum.any?(
            Map.get(payload, "input", []),
            &match?(%{"type" => "function_call_output"}, &1)
          )

      if has_tool_output do
        {200, streamed_reply(conn.request_path, "Done — lead dispatched.", "gpt-4.1-mini")}
      else
        {200,
         tool_call_reply(
           conn.request_path,
           "dispatch_event",
           ~s({"event_name":"lead_identified","input":{"email":"lead@acme.com"}}),
           "gpt-4.1-mini"
         )}
      end
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Dispatch Event Agent Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Dispatch Event Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Use the dispatch_event tool to dispatch a lead_identified event, then answer.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["workflow.dispatch_event"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(agent) end)

    incoming = %Incoming{content: "dispatch a lead", channel_id: "bo-test", provider: :web}

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(agent.id),
        node_router: CaptureRouter,
        status_module: StubStatus
      )

    assert is_binary(outgoing.body)

    # The tool actually dispatched the event to the engine via the injected router.
    assert_receive {:dispatched, %Event{name: "lead_identified"} = event}, 2_000
    assert event.next_hop.destination == :engine
    assert event.request == %{"email" => "lead@acme.com"}
  end

  # ── OpenAI Responses-API stub helpers (mirrors the channels/agent suites) ──────

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

  defp tool_call_reply("/v1/chat/completions", _tool_name, _arguments_json, model) do
    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-tool",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      })

    "data: #{done_chunk}\n\ndata: [DONE]\n\n"
  end

  defp tool_call_reply(_path, tool_name, arguments_json, model) do
    # `output_item.added` registers the tool call with `expects_arg_fragments`;
    # ReqLLM then accumulates the arguments from the streamed
    # `function_call_arguments.delta` events (matched by `output_index`). Inlining
    # arguments only on the item/completed output is NOT enough — they are lost.
    output_item =
      Jason.encode!(%{
        "output_index" => 0,
        "item" => %{
          "type" => "function_call",
          "call_id" => "call_dispatch_1",
          "id" => "call_dispatch_1",
          "name" => tool_name,
          "arguments" => ""
        }
      })

    args_delta =
      Jason.encode!(%{
        "output_index" => 0,
        "item_id" => "call_dispatch_1",
        "delta" => arguments_json
      })

    args_done =
      Jason.encode!(%{
        "output_index" => 0,
        "item_id" => "call_dispatch_1",
        "arguments" => arguments_json
      })

    completed_event =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_tool_1",
          "model" => model,
          "status" => "completed",
          "output" => [
            %{
              "type" => "function_call",
              "id" => "call_dispatch_1",
              "name" => tool_name,
              "arguments" => arguments_json
            }
          ],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    [
      "event: response.output_item.added\n",
      "data: #{output_item}\n\n",
      "event: response.function_call_arguments.delta\n",
      "data: #{args_delta}\n\n",
      "event: response.function_call_arguments.done\n",
      "data: #{args_done}\n\n",
      "event: response.completed\n",
      "data: #{completed_event}\n\n"
    ]
    |> IO.iodata_to_binary()
  end
end
