defmodule Zaq.Channels.WebBridgeCommandFailuresTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Command, Context, Message, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Engine.Conversations.Message, as: ConversationMessage
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{opts: opts} = event) do
      action = Keyword.fetch!(opts, :action)
      send(Process.get(:test_owner, self()), {:dispatched, action, event.request})

      case {action, Process.get(:router_mode)} do
        {:conversation, :raise} ->
          raise "private"

        {:conversation, :raw} ->
          :unavailable

        {:conversation, _} ->
          request = event.request

          response =
            case request.action do
              :display_history -> Process.get(:history_reply, nil)
              :resolve_display_conversation -> Process.get(:resolve_reply, nil)
              :create -> Process.get(:create_reply, {:ok, %{id: "created"}})
            end

          %{event | response: response}

        {:route_incoming_message, :raise} ->
          raise "private"

        {:route_incoming_message, _} ->
          %{event | response: Process.get(:route_reply, {:error, :rejected})}
      end
    end
  end

  defp context(actor \\ %{user_id: 11}) do
    {:ok, ctx} = Context.new(actor, consumer: :bo)
    ctx
  end

  defp command(type, attrs \\ %{}) do
    {:ok, cmd} = Command.new(Map.merge(%{request_id: "request", type: type}, attrs))
    cmd
  end

  defp message do
    {:ok, msg} =
      Message.new(%{
        request_id: "request",
        message_id: "message",
        content: "question",
        channel: "bo",
        mode: :async,
        timestamp: DateTime.utc_now()
      })

    msg
  end

  test "requires context and an authorized BO actor" do
    assert {:error, :missing_web_context} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init), node_router: Router)

    assert {:error, :unauthorized} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init),
               context: context(nil),
               node_router: Router
             )

    refute_receive {:dispatched, _, _}
  end

  test "rescues BO route dispatch failures" do
    Process.put(:router_mode, :raise)

    assert {:error, :dispatch_error} =
             WebBridge.handle_from_listener(%{}, message(),
               context: context(),
               node_router: Router
             )
  after
    Process.delete(:router_mode)
  end

  test "history requires a conversation id and reports lookup failures" do
    assert %Response{type: :error, payload: %{code: :conversation_id_required}} =
             WebBridge.handle_from_listener(%{}, command(:conversation_history),
               context: context(),
               node_router: Router
             )

    Process.put(:history_reply, nil)

    assert %Response{payload: %{code: :conversation_not_found}} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_history, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )
  after
    Process.delete(:history_reply)
  end

  test "history rejects malformed engine replies" do
    Process.put(
      :history_reply,
      {:ok, %{conversation: %Conversation{id: "c"}, messages: :malformed}}
    )

    assert %Response{request_id: "request", payload: %{code: :history_unavailable}} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_history, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    assert_receive {:dispatched, :conversation, %{action: :display_history, conversation_id: "c"}}
  after
    Process.delete(:history_reply)
  end

  test "history rejects malformed success envelopes before projection" do
    for reply <- [
          {:ok, %{}},
          {:ok, %{conversation: nil, messages: []}},
          {:ok, %{conversation: %{id: "c"}, messages: []}},
          {:ok, %{conversation: %Conversation{}, messages: []}},
          {:ok, %{conversation: %Conversation{id: 42}, messages: []}},
          {:ok, %{conversation: %Conversation{id: "c"}, messages: nil}},
          {:ok, %{conversation: %Conversation{id: "c"}, messages: %{}}}
        ] do
      Process.put(:history_reply, reply)

      assert %Response{request_id: "request", payload: %{code: :history_unavailable}} =
               WebBridge.handle_from_listener(
                 %{},
                 command(:conversation_history, %{conversation_id: "c"}),
                 context: context(),
                 node_router: Router
               )
    end
  after
    Process.delete(:history_reply)
  end

  test "history distinguishes forbidden, sanitized private data, and opaque engine errors" do
    Process.put(:history_reply, {:error, :forbidden})

    assert %Response{payload: %{code: :forbidden}} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_history, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    Process.put(
      :history_reply,
      {:ok,
       %{
         conversation: %Conversation{id: "c"},
         messages: [%ConversationMessage{ratings: [], metadata: %{"token" => "private"}}]
       }}
    )

    assert %Response{payload: %{code: :invalid_response_payload} = payload} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_history, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    refute inspect(payload) =~ "private"
    Process.put(:history_reply, {:error, "private reason"})

    assert %Response{payload: %{code: :operation_failed} = payload} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_history, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    refute inspect(payload) =~ "private reason"
  after
    Process.delete(:history_reply)
  end

  test "initialization maps forbidden and unavailable replies" do
    Process.put(:resolve_reply, {:error, :forbidden})

    assert %Response{payload: %{code: :forbidden}} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_init, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    Process.put(:router_mode, :raw)

    assert %Response{payload: %{code: :engine_unavailable}} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init),
               context: context(),
               node_router: Router
             )
  after
    [:resolve_reply, :router_mode] |> Enum.each(&Process.delete/1)
  end

  test "initialization maps malformed resolution and create event responses" do
    Process.put(:resolve_reply, {:unexpected, :response})

    assert %Response{payload: %{code: :conversation_unavailable}} =
             WebBridge.handle_from_listener(
               %{},
               command(:conversation_init, %{conversation_id: "c"}),
               context: context(),
               node_router: Router
             )

    Process.put(:create_reply, :malformed)

    assert %Response{payload: %{code: :conversation_create_failed}} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init),
               context: context(),
               node_router: Router
             )
  after
    [:resolve_reply, :create_reply] |> Enum.each(&Process.delete/1)
  end

  test "create dispatch scopes the BO user and rejects missing identity" do
    Process.put(:test_owner, self())

    assert %Response{type: :conversation_initialized} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init),
               context: context(%{"user_id" => 42}),
               node_router: Router
             )

    assert_receive {:dispatched, :conversation,
                    %{action: :create, attrs: %{channel_user_id: "bo_user_42"}}}

    Process.put(:test_owner, self())

    assert %Response{payload: %{code: :unauthorized}} =
             WebBridge.handle_from_listener(%{}, command(:conversation_init),
               context: context(%{}),
               node_router: Router
             )

    refute_receive {:dispatched, :conversation, %{action: :create}}
  after
    Process.delete(:test_owner)
  end

  test "failed ingress does not publish a BO response without delivery" do
    Process.put(:route_reply, %Zaq.Engine.Messages.Outgoing{
      body: "error",
      provider: :web,
      channel_id: "bo",
      metadata: %{error: true}
    })

    assert %Zaq.Engine.Messages.Outgoing{} =
             WebBridge.handle_from_listener(%{}, message(),
               context: context(),
               node_router: Router
             )

    refute_receive {:web_response, _, _}
  after
    Process.delete(:route_reply)
  end

  test "projects person identity and omits absent delivery scope" do
    actor = %{"person" => %{id: 9, full_name: "A", team_ids: []}}
    incoming = WebBridge.to_internal(message(), context(actor))
    assert incoming.person.id == 9
    assert incoming.routing_context.channel_config_id == nil
    refute Map.has_key?(incoming.routing_context.attributes, "web_delivery")
  end
end
