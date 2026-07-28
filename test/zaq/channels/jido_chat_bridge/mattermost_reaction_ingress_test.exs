defmodule Zaq.Channels.JidoChatBridge.MattermostReactionIngressTest do
  @moduledoc """
  Regression test for the ZAQ side of Mattermost reaction ingress.

  The Mattermost adapter owns WebSocket frame parsing and emits a normalized
  `%Jido.Chat.EventEnvelope{}` for reactions. These tests feed that envelope into
  the bridge state process and verify it reaches Engine as a rating event.
  """
  use ExUnit.Case, async: false

  alias Jido.Chat.EventEnvelope
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State

  defmodule StubAdapter do
    def transform_incoming(_payload), do: {:error, :unsupported_payload}
  end

  defmodule CapturingNodeRouter do
    def dispatch(event) do
      if pid = Process.whereis(:mattermost_reaction_observer) do
        send(pid, {:node_router_dispatch, event})
      end

      %{event | response: {:ok, %{}}}
    end
  end

  setup do
    previous_channels = Application.get_env(:zaq, :channels, %{})
    previous_router = Application.get_env(:zaq, :chat_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{
        bridge: JidoChatBridge,
        adapter: StubAdapter,
        ingress_mode: :websocket
      }
    })

    Application.put_env(:zaq, :chat_bridge_node_router_module, CapturingNodeRouter)

    config = %{
      provider: "mattermost",
      url: "https://mm.example.com",
      token: "tok",
      settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-uid"}}
    }

    {:ok, pid} =
      State.start_link(
        bridge_id: "mattermost_1",
        config: config,
        provider: :mattermost,
        handler_opts: %{}
      )

    Process.register(self(), :mattermost_reaction_observer)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      Application.put_env(:zaq, :channels, previous_channels)

      if previous_router do
        Application.put_env(:zaq, :chat_bridge_node_router_module, previous_router)
      else
        Application.delete_env(:zaq, :chat_bridge_node_router_module)
      end
    end)

    {:ok, pid: pid, config: config}
  end

  defp reaction_envelope(emoji_name, event_name \\ "reaction_added") do
    channel_id = "chan-abc"
    post_id = "post-1"
    user_id = "user-123"
    thread_id = "mattermost:#{channel_id}"
    added = event_name == "reaction_added"

    reaction =
      %{
        "user_id" => user_id,
        "post_id" => post_id,
        "emoji_name" => emoji_name,
        "create_at" => 1_700_000_000
      }

    EventEnvelope.new(%{
      adapter_name: :mattermost,
      event_type: :reaction,
      thread_id: thread_id,
      channel_id: channel_id,
      message_id: post_id,
      payload: %{
        adapter_name: :mattermost,
        thread_id: thread_id,
        channel_id: channel_id,
        message_id: post_id,
        emoji: emoji_name,
        added: added,
        user: %{user_id: user_id},
        raw: reaction,
        metadata: %{channel_id: channel_id}
      },
      raw: %{
        "event" => event_name,
        "data" => %{"reaction" => Jason.encode!(reaction), "channel_type" => "D"},
        "broadcast" => %{"channel_id" => channel_id}
      },
      metadata: %{source: :websocket, ws_event: event_name}
    })
  end

  defp deliver(pid, config, envelope) do
    State.process_listener_payload(pid, config, envelope, transport: "websocket")
  end

  test "a thumbs-up reaction reaches the engine as a rating", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_envelope("thumbsup"))

    assert_received {:node_router_dispatch, event}
    assert event.opts[:action] == :rate_message

    # Identical to the shape `telegram_reaction_webhook_test.exs` asserts: the
    # two ingress modes converge on one origin-agnostic rating payload.
    assert %{
             message_ref: {:external_id, "post-1"},
             rater_attrs: %{channel_user_id: "user-123", rating: 5}
           } = event.request
  end

  test "a thumbs-down reaction reaches the engine as a low rating", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_envelope("thumbsdown"))

    assert_received {:node_router_dispatch, event}
    assert event.request.rater_attrs.rating == 1
  end

  test "removing a reaction dispatches nothing", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_envelope("thumbsup", "reaction_removed"))

    refute_received {:node_router_dispatch, _event}
  end

  test "an unmapped emoji dispatches nothing", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_envelope("tada"))

    refute_received {:node_router_dispatch, _event}
  end
end
