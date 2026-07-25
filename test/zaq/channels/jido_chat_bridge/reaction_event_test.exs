defmodule Zaq.Channels.JidoChatBridge.ReactionEventTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.ReactionEvent
  alias Jido.Chat.Thread
  alias Zaq.Channels.JidoChatBridge

  defmodule CapturingNodeRouter do
    def dispatch(event) do
      send(self(), {:reaction_event_dispatched, event})

      response =
        case Process.get(:reaction_follow_up) do
          nil -> {:ok, %{}}
          text -> {:ok, %{follow_up_text: text}}
        end

      %{event | response: response}
    end
  end

  defmodule StubPostAdapter do
    def send_message(room_id, payload, opts) do
      send(self(), {:reaction_follow_up_posted, room_id, payload, opts})

      {:ok, %{external_message_id: "sent-1", raw: %{}}}
    end
  end

  setup do
    previous = Application.get_env(:zaq, :chat_bridge_node_router_module)
    Application.put_env(:zaq, :chat_bridge_node_router_module, CapturingNodeRouter)

    on_exit(fn ->
      if previous do
        Application.put_env(:zaq, :chat_bridge_node_router_module, previous)
      else
        Application.delete_env(:zaq, :chat_bridge_node_router_module)
      end
    end)

    {:ok, config: %{provider: "mattermost", url: "https://mm.example.com", token: "tok"}}
  end

  defp reaction(overrides \\ %{}) do
    %{
      id: "evt-1",
      adapter_name: :mattermost,
      adapter: StubPostAdapter,
      thread_id: "mattermost:chan-1",
      channel_id: "chan-1",
      message_id: "msg-1",
      emoji: "thumbsup",
      added: true,
      user: %{user_id: "user-1", user_name: "user-1"}
    }
    |> Map.merge(overrides)
    |> ReactionEvent.new()
  end

  defp thread do
    Thread.new(%{
      id: "mattermost:chan-1",
      adapter: StubPostAdapter,
      adapter_name: :mattermost,
      external_room_id: "chan-1",
      metadata: %{}
    })
  end

  test "dispatches a rating event for a mapped emoji", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction())

    assert_received {:reaction_event_dispatched, event}
    assert event.opts[:action] == :rate_message_from_reaction
    assert %{reaction: rated} = event.request
    assert rated.rating == 5
    assert rated.message_id == "msg-1"
  end

  test "maps a negative emoji to the low rating", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction(%{emoji: "thumbsdown"}))

    assert_received {:reaction_event_dispatched, event}
    assert event.request.reaction.rating == 1
  end

  test "ignores reaction removals", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction(%{added: false}))

    refute_received {:reaction_event_dispatched, _event}
  end

  test "ignores unmapped emoji", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction(%{emoji: "tada"}))

    refute_received {:reaction_event_dispatched, _event}
  end

  test "ignores a reaction with no emoji instead of raising", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction(%{emoji: nil}))

    refute_received {:reaction_event_dispatched, _event}
  end

  test "posts the engine follow-up back to the thread", %{config: config} do
    Process.put(:reaction_follow_up, "Thanks for the feedback!")
    on_exit(fn -> Process.delete(:reaction_follow_up) end)

    JidoChatBridge.handle_reaction_event(config, reaction(%{thread: thread()}))

    assert_received {:reaction_follow_up_posted, "chan-1", payload, opts}
    assert payload == "Thanks for the feedback!"
    assert opts[:url] == "https://mm.example.com"
    assert opts[:token] == "tok"
  end

  test "rates without posting when the reaction carries no thread handle", %{config: config} do
    Process.put(:reaction_follow_up, "Thanks for the feedback!")
    on_exit(fn -> Process.delete(:reaction_follow_up) end)

    assert :ok = JidoChatBridge.handle_reaction_event(config, reaction(%{thread: nil}))

    assert_received {:reaction_event_dispatched, _event}
    refute_received {:reaction_follow_up_posted, _room, _payload, _opts}
  end

  test "ignores payloads that are not reaction events", %{config: config} do
    assert :ok = JidoChatBridge.handle_reaction_event(config, %{emoji: "thumbsup", added: true})
    assert :ok = JidoChatBridge.handle_reaction_event(config, nil)

    refute_received {:reaction_event_dispatched, _event}
  end
end
