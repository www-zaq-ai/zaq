# Run in an isolated BEAM so the package's singleton infrastructure does not
# replace the ZAQ application's real widget configuration or authentication.
# MIX_ENV=test mix run --no-start test/support/web_widget_identity_smoke.exs
directory =
  Path.join(System.tmp_dir!(), "zaq-widget-identity-#{System.system_time(:microsecond)}")

File.mkdir!(directory)
Application.put_env(:mnesia, :dir, String.to_charlist(directory))
{:ok, _} = Application.ensure_all_started(:web_widget)
ExUnit.start(autorun: false)

System.at_exit(fn _ ->
  Application.stop(:mnesia)
  File.rm_rf!(directory)
end)

defmodule Zaq.WebWidgetIdentitySmokeTest do
  # credo:disable-for-next-line Credo.Check.Warning.WrongTestFilename
  use ExUnit.Case, async: false

  alias WebWidget.{Connector, Runtime}
  alias WebWidget.Integration.Chat
  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Engine.Messages.Outgoing

  @answer "11111111-1111-4111-8111-111111111111"
  @input "22222222-2222-4222-8222-222222222222"
  @child "33333333-3333-4333-8333-333333333333"
  @conversation "identity-conversation"

  setup do
    start_supervised!({Phoenix.PubSub, name: Zaq.PubSub})

    start_supervised!(
      {WebWidget, pubsub_server: Zaq.PubSub, identity_verifier: {__MODULE__, :verify, []}}
    )

    config = %{
      id: 42,
      provider: :web_widget,
      token: String.duplicate("widget-identity-test-only", 3),
      settings: %{
        "identity_issuer" => "fixture",
        "identity_audience" => "widget",
        "same_site" => "Lax"
      }
    }

    hooks = %{
      widget_id: 42,
      display_name: "Identity contract",
      allowed_domains: ["https://parent.example"],
      message: Message,
      command: Command,
      response: Response,
      context: Context,
      delivery: Delivery,
      sink_mfa: {__MODULE__, :ingress, [config]}
    }

    start_supervised!({Connector, config: config, hooks: hooks})
    await_runtime(System.monotonic_time(:millisecond) + 5_000)
    :ok
  end

  # Identity verification is the external host boundary, not a bypass of Chat or
  # Runtime authorization. The real runtime still creates and validates sessions.
  def verify(:fixture_session, %{channel_config_id: 42}),
    do: {:ok, %{sender_id: "fixture-person", expires_at: System.system_time(:second) + 60}}

  def verify(_, _), do: {:error, :unauthorized}

  def ingress(%{id: 42}, %Command{type: :conversation_history} = command, context: _context) do
    {:ok, response} =
      Response.new(%{
        protocol_version: 2,
        request_id: command.request_id,
        conversation_id: command.conversation_id,
        type: :conversation_history,
        payload: %{processing: :idle, messages: Process.get(:identity_history, [])}
      })

    response
  end

  def ingress(%{id: 42}, %Command{} = command, context: context) do
    assert context.sender_id == "fixture-person"

    {:ok, response} =
      Response.new(%{
        protocol_version: 2,
        request_id: command.request_id,
        conversation_id: command.conversation_id,
        type: :widget_initialized,
        payload: %{created: false}
      })

    %{response: response, delivery_binding: delivery()}
  end

  def ingress(%{id: 42}, %Message{} = message, context: context) do
    assert context.sender_id == "fixture-person"

    {:ok, response} =
      Response.new(%{
        protocol_version: 2,
        request_id: message.request_id,
        conversation_id: @conversation,
        type: :status,
        payload: %{
          accepted: true,
          created: false,
          user_message: %{
            message_id: @child,
            position: 2,
            role: "user",
            content: message.content,
            provider_sent_at: nil
          }
        }
      })

    if message.mode == :async, do: {:ok, response}, else: response
  end

  test "actual pinned Chat consumes unified host IDs while an additional submission stays separate" do
    chat = open_chat()
    assert Runtime.authorized?(chat.session)
    assert {:ok, %{message_id: @answer}} = status(:execution_started)
    chat = drain(chat)
    assert [%{id: @answer, role: "assistant"}] = assistants(chat)

    assert {:ok, chat} = Chat.submit(chat, "Additional input")
    assert chat.pending_submission == nil
    assert chat.state.pending_reply == nil
    assert length(assistants(chat)) == 1
    assert Enum.any?(chat.state.messages, &(&1.role == "user" and &1.id == @child))
    assert chat.streams[@answer].request_id == "root-submission"

    assert {:ok, %{message_id: @answer}} = status(:answering, @answer, :stream_delta)
    chat = drain(chat)
    assert [%{id: @answer, content: "Partial"}] = assistants(chat)

    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing(), %{})
    chat = drain(chat)
    assert [%{id: @answer, content: "Complete", status: "complete"}] = assistants(chat)
    assert chat.persisted_refs[@answer].assistant_message_id == @answer
    assert chat.streams[@answer].request_id == "root-submission"
    Chat.close(chat)
  end

  test "canonical history overlap suppresses a duplicate terminal after authorized reopen" do
    chat = open_chat()
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing(), %{})
    chat = drain(chat)
    assert [%{id: @answer, status: "complete"}] = assistants(chat)
    Chat.close(chat)

    Process.put(:identity_history, [
      %{
        message_id: @answer,
        position: 1,
        role: "assistant",
        content: "Complete",
        provider_sent_at: nil
      }
    ])

    restored = open_chat()
    assert [%{id: @answer, status: "complete"}] = assistants(restored)
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing(), %{})
    restored = drain(restored)
    assert [%{id: @answer, content: "Complete", status: "complete"}] = assistants(restored)

    legacy = %{delivery() | message_id: "older-transport"}
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing(legacy), %{})
    restored = drain(restored)
    assert [%{id: @answer, content: "Complete", status: "complete"}] = assistants(restored)
    assert restored.persisted_refs["older-transport"].assistant_message_id == @answer
    Chat.close(restored)
  end

  test "older split-ID host events retain canonical association in the actual pinned consumer" do
    chat = open_chat()
    legacy = %{delivery() | message_id: "older-transport"}
    assert {:ok, %{message_id: "older-transport"}} = status(:execution_started, nil, nil, legacy)
    chat = drain(chat)
    assert [%{id: "older-transport"}] = assistants(chat)
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing(legacy), %{})
    chat = drain(chat)
    assert [%{id: "older-transport", status: "complete"}] = assistants(chat)
    assert chat.persisted_refs["older-transport"].assistant_message_id == @answer
    Chat.close(chat)
  end

  test "accepted prestream failure uses the same canonical consumer row without history" do
    chat = open_chat()

    failed = %{
      outgoing()
      | body: "Unable to answer",
        metadata: Map.merge(outgoing().metadata, %{error: true})
    }

    assert {:ok, %{delivered: true}} = WebBridge.send_reply(failed, %{})
    chat = drain(chat)
    assert [%{id: @answer, status: "failed"}] = assistants(chat)
    Chat.close(chat)
    opened = open_chat()
    assert assistants(opened) == []
    Chat.close(opened)
  end

  test "explicitly absent persistence never becomes a saved-answer reference in the pinned consumer" do
    chat = open_chat()
    answer = outgoing()

    answer = %{
      answer
      | metadata:
          Map.merge(
            answer.metadata,
            %{error: false, suppressed: true, persisted_assistant_message_id: nil}
          )
    }

    assert {:ok, %{delivered: true}} = WebBridge.send_reply(answer, %{})
    chat = drain(chat)
    assert [%{id: @answer, status: "complete"}] = assistants(chat)
    assert chat.persisted_refs[@answer][:assistant_message_id] == nil
    Chat.close(chat)
  end

  test "pinned widget receives streamed tools and restores their terminal snapshot" do
    chat = open_chat()
    assert {:ok, _} = status(:execution_started)
    chat = drain(chat)

    running = %{
      "id" => "lookup",
      "kind" => "tool",
      "name" => "lookup",
      "label" => "Lookup",
      "sequence" => 1,
      "state" => "running"
    }

    assert {:ok, _} =
             WebBridge.upsert_message(
               %{},
               %{
                 request_id: "root-submission",
                 assistant_message_id: @answer,
                 message_id: @answer,
                 body: "Working",
                 intent_meta: %{stage: :tool_call},
                 update_intent: :tool_call,
                 routing_context: routing(delivery()),
                 tool_steps: [Map.put(running, "params", "private")]
               },
               %{}
             )

    chat = drain(chat)
    assert [%{steps: [%{id: "lookup", state: "started", sequence: 1}]}] = assistants(chat)
    refute inspect(assistants(chat)) =~ "private"

    settled = Map.merge(running, %{"state" => "succeeded", "duration_ms" => 21})
    final = outgoing()
    final = %{final | metadata: Map.put(final.metadata, :tool_steps, [settled])}
    assert {:ok, _} = WebBridge.send_reply(final, %{})
    chat = drain(chat)
    assert [%{steps: [%{state: "completed", duration_ms: 21}]}] = assistants(chat)
    expected = hd(assistants(chat)).steps
    Chat.close(chat)

    Process.put(:identity_history, [
      %{
        message_id: @answer,
        position: 1,
        role: "assistant",
        content: "Complete",
        tool_steps: [settled]
      }
    ])

    restored = open_chat()
    assert hd(assistants(restored)).steps == expected
    assert {:ok, _} = status(:answering, @answer, :stream_delta)
    restored = drain(restored)
    assert hd(assistants(restored)).steps == expected
    Chat.close(restored)
  end

  defp open_chat do
    assert {:ok, chat} =
             Chat.open("42", %{"identity_token" => :fixture_session}, nil, @conversation)

    chat
  end

  defp assistants(chat), do: Enum.filter(chat.state.messages, &(&1.role == "assistant"))

  defp status(stage, handle \\ nil, intent \\ nil, destination \\ delivery()) do
    WebBridge.upsert_message(
      %{},
      %{
        request_id: "root-submission",
        assistant_message_id: @answer,
        message_id: handle,
        body: "Partial",
        intent_meta: %{stage: stage},
        update_intent: intent,
        routing_context: routing(destination)
      },
      %{}
    )
  end

  defp outgoing(destination \\ delivery()) do
    %Outgoing{
      provider: :web_widget,
      channel_id: "room",
      body: "Complete",
      in_reply_to: @input,
      routing_context: routing(destination),
      metadata: %{
        request_id: "root-submission",
        assistant_message_id: @answer,
        user_message_id: @input,
        status_message_id: destination.message_id
      }
    }
  end

  defp routing(destination),
    do: %RoutingContext{
      channel_config_id: 42,
      attributes: %{"web_delivery" => Delivery.reference(destination)}
    }

  defp delivery do
    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        channel_config_id: 42,
        topic: "identity-recipient:42",
        conversation_id: @conversation,
        events: %{
          user_message: "response.user_message",
          typing: "response.typing",
          message_create: "response.message.create",
          message_edit: "response.message.edit",
          message_step: "response.message.step",
          message_complete: "response.message.complete",
          message_failed: "response.message.failed",
          error: "response.error"
        }
      })

    delivery
  end

  defp drain(chat) do
    receive do
      {:web_response, event, %Response{} = response} ->
        chat |> Chat.receive_response(event, response) |> drain()
    after
      0 -> chat
    end
  end

  defp await_runtime(deadline) do
    if Runtime.integrated?("42") do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline

      receive do
      after
        10 -> await_runtime(deadline)
      end
    end
  end
end

result = ExUnit.run()
Application.stop(:mnesia)
File.rm_rf!(directory)
System.halt(if result.failures == 0, do: 0, else: 1)
