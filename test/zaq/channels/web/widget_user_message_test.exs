defmodule Zaq.Channels.Web.WidgetUserMessageTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Channels.Web.{Command, Context, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Api, as: EngineApi
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Engine.Conversations.Message, as: SavedMessage
  alias Zaq.Event

  defmodule UnavailableAcknowledgement do
    def dispatch(%Event{request: %{operation: :accepted_message}} = event),
      do: %{event | response: {:error, :unavailable}}

    def dispatch(event), do: Zaq.NodeRouter.dispatch(event)
    def fire(event), do: Zaq.NodeRouter.fire(event)
  end

  setup do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "User sync",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, %{routing_mode: :none})

    {:ok, init} = Command.new(%{request_id: "init", type: :conversation_init})

    {:ok, context} =
      Context.new(nil, consumer: :widget, sender_id: "user-sync", channel_config_id: config.id)

    assert %{delivery_binding: binding} = WebBridge.from_listener(%{}, init, context: context)
    Phoenix.PubSub.subscribe(Zaq.PubSub, binding.topic)
    %{context: %{context | delivery: binding}, config: config}
  end

  test "accepted user record is identical in receipt, both tabs and authorized history", %{
    context: context
  } do
    owner = self()

    tab =
      spawn_link(fn ->
        Phoenix.PubSub.subscribe(Zaq.PubSub, context.delivery.topic)
        send(owner, :second_tab_ready)

        receive do
          event -> send(owner, {:second_tab_event, event})
        end
      end)

    assert_receive :second_tab_ready
    message = message("Saved question")

    assert {:ok,
            %Response{payload: %{accepted: true, created: true, user_message: saved}} = receipt} =
             WebBridge.from_listener(%{}, message, context: context)

    assert saved.role == "user"
    assert saved.content == message.content
    assert is_integer(saved.position) and saved.position > 0
    refute saved.message_id == message.message_id

    assert_receive {:web_response, "response.user_message",
                    %Response{type: :user_message, message_id: nil} = event}

    assert event.payload == receipt.payload
    assert event.request_id == message.request_id
    assert_receive {:second_tab_event, {:web_response, "response.user_message", ^event}}
    refute_receive {:web_response, "response.user_message", _}

    {:ok, history} =
      Command.new(%{
        request_id: "history",
        type: :conversation_history,
        conversation_id: receipt.conversation_id
      })

    assert %Response{payload: %{messages: [^saved]}} =
             WebBridge.from_listener(%{}, history, context: context)

    refute Map.has_key?(saved, :metadata)
    refute Map.has_key?(saved, :execution_id)
    monitor = Process.monitor(tab)
    assert_receive {:DOWN, ^monitor, :process, ^tab, _}
  end

  property "accepted user identifiers and payloads remain canonical across replay", %{
    context: context
  } do
    check all(content <- string(:alphanumeric, min_length: 1, max_length: 60), max_runs: 5) do
      message = message(content)
      assert {:ok, receipt} = WebBridge.from_listener(%{}, message, context: context)
      resumed = %{message | conversation_id: receipt.conversation_id}
      assert {:ok, replay} = WebBridge.from_listener(%{}, resumed, context: context)
      assert replay.payload.user_message == receipt.payload.user_message
      assert_receive {:web_response, "response.user_message", first}
      assert_receive {:web_response, "response.user_message", second}
      assert first.payload.user_message.message_id == second.payload.user_message.message_id
    end
  end

  test "foreign conversation produces no accepted broadcast", %{context: context} do
    assert {:ok, receipt} = WebBridge.from_listener(%{}, message("Private"), context: context)
    assert_receive {:web_response, "response.user_message", _}
    foreign = %{context | sender_id: "someone-else"}
    question = %{message("Forbidden") | conversation_id: receipt.conversation_id}

    assert {:error, :conversation_not_found} =
             WebBridge.from_listener(%{}, question, context: foreign)

    refute_receive {:web_response, "response.user_message", _}
  end

  test "saved input with unavailable acknowledgement stays unknown and is not broadcast", %{
    context: context
  } do
    result =
      WebBridge.handle_from_listener(%{}, message("Saved despite unavailable receipt"),
        context: context,
        node_router: UnavailableAcknowledgement
      )

    assert %Response{
             type: :error,
             conversation_id: id,
             payload: %{code: :acknowledgement_unavailable, outcome: :unknown}
           } = result

    assert is_binary(id)
    refute_receive {:web_response, "response.user_message", _}

    {:ok, history} =
      Command.new(%{request_id: "history", type: :conversation_history, conversation_id: id})

    assert %Response{payload: %{messages: [%{content: "Saved despite unavailable receipt"}]}} =
             WebBridge.from_listener(%{}, history, context: context)
  end

  test "accepted lookup reauthorizes and filters exact external message ID", %{context: context} do
    question = message("Exact record")
    result = WebBridge.from_listener(%{}, question, context: context)
    conversation = Repo.one!(Conversation)

    assert Repo.one!(from(m in SavedMessage, select: m.external_message_id)) ==
             question.message_id

    scope = %{
      operation: :accepted_message,
      channel_config_id: context.channel_config_id,
      sender_id: context.sender_id,
      conversation_id: conversation.id,
      external_message_id: question.message_id
    }

    event = Event.new(scope, :engine)

    assert %{response: {:ok, row}} =
             EngineApi.handle_event(event, :channel_conversations, nil)

    assert {:ok, receipt} = result
    assert %{row | role: "user"} == receipt.payload.user_message

    assert %{response: {:error, :message_not_found}} =
             EngineApi.handle_event(
               %{event | request: %{scope | external_message_id: "missing"}},
               :channel_conversations,
               nil
             )

    assert %{response: {:error, :conversation_not_found}} =
             EngineApi.handle_event(
               %{event | request: %{scope | sender_id: "foreign"}},
               :channel_conversations,
               nil
             )
  end

  defp message(content) do
    {:ok, message} =
      Message.new(%{
        request_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        timestamp: DateTime.utc_now(),
        content: content,
        channel: "web_widget",
        mode: :async
      })

    message
  end
end
