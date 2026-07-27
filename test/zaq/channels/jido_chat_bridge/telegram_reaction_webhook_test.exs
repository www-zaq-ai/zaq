defmodule Zaq.Channels.JidoChatBridge.TelegramReactionWebhookTest do
  @moduledoc """
  End-to-end regression test for the Telegram reaction ingress seam.

  Telegram runs in `:webhook` ingress mode, so reactions never touch
  `process_listener_payload/4` — they arrive as a raw `message_reaction` update
  and are routed by `Jido.Chat` to the `on_reaction/2` handler registered in
  `JidoChatBridge.register_handlers/3`. This exercises that whole chain with the
  real Telegram adapter, stubbing only the node router at the far end.
  """
  use ExUnit.Case, async: false

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State

  defmodule CapturingNodeRouter do
    def dispatch(event) do
      if pid = Process.whereis(:telegram_reaction_observer) do
        send(pid, {:node_router_dispatch, event})
      end

      %{event | response: {:ok, %{}}}
    end
  end

  setup do
    previous_channels = Application.get_env(:zaq, :channels, %{})
    previous_router = Application.get_env(:zaq, :chat_bridge_node_router_module)

    Application.put_env(:zaq, :channels, %{
      telegram: %{
        bridge: JidoChatBridge,
        adapter: Jido.Chat.Telegram.Adapter,
        ingress_mode: :webhook
      }
    })

    Application.put_env(:zaq, :chat_bridge_node_router_module, CapturingNodeRouter)

    config = %{
      provider: "telegram",
      url: "https://api.telegram.org",
      token: "tok",
      settings: %{"jido_chat" => %{"bot_name" => "zaq", "bot_user_id" => "bot-1"}}
    }

    {:ok, pid} =
      State.start_link(
        bridge_id: "telegram_1",
        config: config,
        provider: :telegram,
        handler_opts: %{}
      )

    Process.register(self(), :telegram_reaction_observer)

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

  # Shape Telegram posts to the webhook for a 👍 reaction.
  defp webhook_payload(emoji \\ "\u{1F44D}") do
    %{
      "method" => "POST",
      "path" => "/channels/webhook/conversation/telegram",
      "headers" => %{},
      "query" => %{},
      "payload" => %{
        "update_id" => 1,
        "message_reaction" => %{
          "chat" => %{"id" => 12_345, "type" => "private"},
          "message_id" => 678,
          "user" => %{"id" => 999, "username" => "jad", "first_name" => "Jad"},
          "date" => 1_700_000_000,
          "old_reaction" => [],
          "new_reaction" => [%{"type" => "emoji", "emoji" => emoji}]
        }
      }
    }
  end

  test "a telegram thumbs-up webhook dispatches a rating event", %{pid: pid, config: config} do
    State.process_webhook_request(pid, config, webhook_payload())

    assert_received {:node_router_dispatch, event}
    assert event.opts[:action] == :rate_message

    # Identical to the shape `mattermost_reaction_ingress_test.exs` asserts —
    # webhook and listener ingress converge on one origin-agnostic payload.
    assert %{message_ref: {:external_id, "678"}, rater_attrs: %{rating: 5}} = event.request
  end

  test "a telegram thumbs-down webhook dispatches the low rating", %{pid: pid, config: config} do
    State.process_webhook_request(pid, config, webhook_payload("\u{1F44E}"))

    assert_received {:node_router_dispatch, event}
    assert event.request.rater_attrs.rating == 1
  end

  test "an unmapped telegram emoji dispatches nothing", %{pid: pid, config: config} do
    State.process_webhook_request(pid, config, webhook_payload("\u{1F914}"))

    refute_received {:node_router_dispatch, _event}
  end
end
