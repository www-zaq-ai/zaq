defmodule ZaqWeb.Chat.BridgeClientTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Web.{Command, Context, Message}
  alias Zaq.Event
  alias ZaqWeb.Chat.BridgeClient

  defmodule UnavailableRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})
      {:error, :transport_down}
    end
  end

  defmodule ReplyRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})
      %{event | response: {:ok, :accepted}}
    end
  end

  test "returns channels unavailable when dispatch does not return an event" do
    actor = %{id: 42, full_name: "BO User"}

    attrs = %{
      request_id: "request-unavailable",
      message_id: "message-unavailable",
      content: "hello",
      timestamp: DateTime.utc_now(),
      channel: "bo",
      mode: :sync
    }

    assert {:error, :channels_unavailable} =
             BridgeClient.dispatch_message(attrs, actor,
               consumer: :bo,
               node_router: UnavailableRouter
             )

    assert_receive {:dispatched,
                    %Event{
                      actor: ^actor,
                      request: %{payload: %Message{}, context: %Context{consumer: :bo}},
                      opts: opts
                    }}

    assert opts[:action] == :web_ingress
    assert opts[:node_router] == UnavailableRouter
  end

  test "retains optional web bridge event options" do
    actor = %{id: 42, full_name: "BO User"}
    web_config = %{marker: :distinctive_web_config}

    assert {:ok, :accepted} =
             BridgeClient.dispatch_command(
               %{request_id: "request-options", type: :conversation_init},
               actor,
               consumer: :bo,
               node_router: ReplyRouter,
               web_bridge_module: Zaq.Channels.WebBridge,
               web_config: web_config
             )

    assert_receive {:dispatched,
                    %Event{
                      request: %{payload: %Command{type: :conversation_init}, context: context},
                      opts: opts
                    }}

    assert opts[:action] == :web_ingress
    assert opts[:node_router] == ReplyRouter
    assert opts[:web_bridge_module] == Zaq.Channels.WebBridge
    assert opts[:web_config] == web_config
    refute Map.has_key?(context, :web_bridge_module)
    refute Map.has_key?(context, :web_config)
  end

  test "BO history always uses confidential transport even if caller opts request otherwise" do
    assert {:ok, :accepted} =
             BridgeClient.dispatch_command(
               %{request_id: "history", type: :conversation_history, conversation_id: "c"},
               %{user_id: 42},
               consumer: :bo,
               node_router: ReplyRouter,
               confidential: false
             )

    assert_receive {:dispatched, %Event{opts: opts}}
    assert opts[:confidential] == true
  end
end
