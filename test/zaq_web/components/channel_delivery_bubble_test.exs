defmodule ZaqWeb.Components.ChannelDeliveryBubbleTest do
  use Zaq.DataCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.ChatMessage

  test "delivery variants retain answer content and do not use generation-error formatting" do
    for {state, label} <- [
          failed: "Delivery failed",
          unconfirmed: "Delivery unconfirmed",
          history_updating: "Delivered — history updating"
        ] do
      html =
        render_component(&ChatMessage.assistant_bubble/1, %{
          content: "**Generated answer**",
          timestamp: ~U[2026-11-10 10:30:00Z],
          msg_id: "answer",
          delivery_state: state
        })

      assert html =~ "data-delivery-state=\"#{state}\""
      assert html =~ "<strong>Generated answer</strong>"
      assert html =~ "zaq-chat-delivery"
      assert html =~ label
      assert html =~ "show details"
      refute html =~ "zaq-feedback-banner"
    end
  end

  test "existing sent bubbles keep their default presentation" do
    html =
      render_component(&ChatMessage.assistant_bubble/1, %{
        content: "Sent answer",
        timestamp: ~U[2026-11-10 10:30:00Z]
      })

    refute html =~ "data-delivery-state"
    refute html =~ "zaq-chat-delivery"
    refute html =~ "delivery-status"
  end
end
