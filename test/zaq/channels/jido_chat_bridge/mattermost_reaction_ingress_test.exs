defmodule Zaq.Channels.JidoChatBridge.MattermostReactionIngressTest do
  @moduledoc """
  End-to-end regression test for the Mattermost reaction ingress seam.

  Mattermost runs in `:websocket` ingress mode, so a reaction has to survive two
  hops that used to be broken: the adapter's WebSocket client (which dropped
  every non-`posted` event) and `process_listener_payload/4` (which could not
  read the resulting envelope). This drives a real Mattermost WS frame through
  `Jido.Chat.Mattermost.WebSocket.Client` and feeds whatever it emits into the
  bridge state process, stubbing only the node router at the far end.
  """
  use ExUnit.Case, async: false

  alias Jido.Chat.Mattermost.WebSocket.Client
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

  def sink_capture(payload, opts) do
    if pid = Process.whereis(:mattermost_reaction_observer) do
      send(pid, {:sink_called, payload, opts})
    end

    :ok
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

  defp ws_state do
    %{
      token: "tok",
      bot_user_id: "bot-uid",
      bot_name: "zaq",
      channel_ids: :all,
      bridge_id: "mattermost_1",
      sink_mfa: {__MODULE__, :sink_capture, []},
      sink_opts: []
    }
  end

  # Shape Mattermost pushes over the WebSocket when a user reacts to a post.
  defp reaction_frame(emoji_name, event_name \\ "reaction_added") do
    reaction =
      Jason.encode!(%{
        "user_id" => "user-123",
        "post_id" => "post-1",
        "emoji_name" => emoji_name,
        "create_at" => 1_700_000_000
      })

    frame =
      Jason.encode!(%{
        "event" => event_name,
        "data" => %{"reaction" => reaction, "channel_type" => "D"},
        "broadcast" => %{"channel_id" => "chan-abc"}
      })

    {:text, frame}
  end

  # Drives the frame through the adapter's WS client, then hands whatever it
  # emitted to the bridge exactly as the sink MFA would in production.
  defp deliver(pid, config, frame) do
    assert {:ok, _ws_state} = Client.handle_in(frame, ws_state())
    assert_received {:sink_called, payload, sink_opts}

    State.process_listener_payload(pid, config, payload, sink_opts)
  end

  test "a thumbs-up reaction reaches the engine as a rating", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_frame("thumbsup"))

    assert_received {:node_router_dispatch, event}
    assert event.opts[:action] == :rate_message_from_reaction
    assert event.request.reaction.rating == 5
    assert event.request.reaction.message_id == "post-1"
    assert event.request.reaction.user.user_id == "user-123"
  end

  test "a thumbs-down reaction reaches the engine as a low rating", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_frame("thumbsdown"))

    assert_received {:node_router_dispatch, event}
    assert event.request.reaction.rating == 1
  end

  test "removing a reaction dispatches nothing", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_frame("thumbsup", "reaction_removed"))

    refute_received {:node_router_dispatch, _event}
  end

  test "an unmapped emoji dispatches nothing", %{pid: pid, config: config} do
    assert :ok = deliver(pid, config, reaction_frame("tada"))

    refute_received {:node_router_dispatch, _event}
  end

  test "the bot's own reaction never reaches the bridge" do
    reaction =
      Jason.encode!(%{"user_id" => "bot-uid", "post_id" => "post-1", "emoji_name" => "thumbsup"})

    frame =
      {:text,
       Jason.encode!(%{
         "event" => "reaction_added",
         "data" => %{"reaction" => reaction, "channel_type" => "D"},
         "broadcast" => %{"channel_id" => "chan-abc"}
       })}

    assert {:ok, _ws_state} = Client.handle_in(frame, ws_state())

    refute_received {:sink_called, _payload, _opts}
  end
end
