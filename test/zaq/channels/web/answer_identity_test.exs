defmodule Zaq.Channels.Web.AnswerIdentityTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Status
  alias Zaq.Channels.Web.{Delivery, Response}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  @answer "11111111-1111-4111-8111-111111111111"
  @input "22222222-2222-4222-8222-222222222222"

  defmodule BridgeSelection do
    alias Zaq.Channels.WebBridge

    def bridge_for(_provider), do: WebBridge
    def bridge_for(_provider, _opts), do: WebBridge
    def fetch_channel_config(provider), do: {:ok, %{provider: to_string(provider)}}
    def fetch_channel_config(provider, id), do: {:ok, %{id: id, provider: to_string(provider)}}
    def fetch_connection_details_for_config(_config), do: %{}
  end

  defmodule Transport do
    alias Zaq.Channels.Api
    alias Zaq.Channels.Web.AnswerIdentityTest.BridgeSelection

    def dispatch(event) do
      event = %{event | opts: Keyword.put(event.opts, :bridge_module, BridgeSelection)}
      Api.handle_event(event, :upsert_message, nil)
    end
  end

  test "BO status and final envelopes use the selected answer, not submission or input identity" do
    delivery = Delivery.bo(subscribe())
    incoming = incoming(delivery, :web)

    updated =
      Status.broadcast(incoming, :answering, "Partial", Transport, update_intent: :stream_delta)

    assert_receive {:web_response, :status_update,
                    %Response{request_id: "submission", message_id: @answer, type: :message_edit}}

    assert updated.metadata.status_message_id == @answer

    outgoing = Outgoing.from_pipeline_result(updated, %{answer: "Complete"})
    assert outgoing.in_reply_to == @input
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing, %{})

    assert_receive {:web_response, :pipeline_result,
                    %Response{
                      request_id: "submission",
                      message_id: @answer,
                      payload: %{assistant_message_id: @answer, user_message_id: @input}
                    }}
  end

  test "unselected BO progress stays request scoped instead of inventing an assistant identity" do
    delivery = Delivery.bo(subscribe())
    incoming = incoming(delivery, :web)
    incoming = %{incoming | metadata: Map.delete(incoming.metadata, :assistant_message_id)}

    updated =
      Status.broadcast(incoming, :answering, "Checking", Transport, update_intent: :stream_delta)

    assert_receive {:web_response, :status_update,
                    %Response{request_id: "submission", message_id: nil, type: :status}}

    assert updated.metadata[:status_message_id] == nil
  end

  test "widget acceptance, edit and final all use the Engine UUID when no legacy transport is bound" do
    incoming = incoming(widget_delivery(), :web_widget)
    updated = Status.broadcast(incoming, :execution_started, "Preparing answer", Transport)

    assert_receive {:web_response, "response.message.create",
                    %Response{request_id: "submission", message_id: @answer}}

    assert updated.metadata.status_message_id == @answer

    updated =
      Status.broadcast(updated, :answering, "Partial", Transport, update_intent: :stream_delta)

    assert_receive {:web_response, "response.message.edit", %Response{message_id: @answer}}

    assert {:ok, %{delivered: true}} =
             WebBridge.send_reply(
               Outgoing.from_pipeline_result(updated, %{answer: "Complete"}),
               %{}
             )

    assert_receive {:web_response, "response.message.complete",
                    %Response{message_id: @answer, payload: %{assistant_message_id: @answer}}}
  end

  test "a nonstreaming widget answer creates and finishes the same canonical message" do
    incoming = incoming(widget_delivery(), :web_widget)

    assert {:ok, %{delivered: true}} =
             WebBridge.send_reply(
               Outgoing.from_pipeline_result(incoming, %{answer: "Complete"}),
               %{}
             )

    assert_receive {:web_response, "response.message.create", %Response{message_id: @answer}}
    assert_receive {:web_response, "response.message.complete", %Response{message_id: @answer}}
  end

  test "an accepted prestream failure creates and fails the same canonical message" do
    incoming = incoming(widget_delivery(), :web_widget)
    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "Unable to answer", error: true})
    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing, %{})
    assert_receive {:web_response, "response.message.create", %Response{message_id: @answer}}

    assert_receive {:web_response, "response.message.failed",
                    %Response{message_id: @answer, payload: %{error: true}}}
  end

  test "an older in-flight widget descriptor retains its transport binding and canonical association" do
    delivery = %{widget_delivery() | message_id: "older-transport"}
    incoming = incoming(delivery, :web_widget)
    incoming = put_in(incoming.metadata[:status_message_id], "older-transport")
    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "Complete"})

    assert {:ok, %{delivered: true}} = WebBridge.send_reply(outgoing, %{})

    assert_receive {:web_response, "response.message.complete",
                    %Response{
                      message_id: "older-transport",
                      payload: %{assistant_message_id: @answer}
                    }}

    refute_received {:web_response, "response.message.create", _}
  end

  defp incoming(delivery, provider) do
    %Incoming{
      content: "Question",
      provider: provider,
      channel_id: "room",
      message_id: @input,
      routing_context: %RoutingContext{
        channel_config_id: delivery.channel_config_id,
        attributes: %{"web_delivery" => Delivery.reference(delivery)}
      },
      metadata: %{
        request_id: "submission",
        assistant_message_id: @answer,
        user_message_id: @input,
        conversation_id: "conversation"
      }
    }
  end

  defp widget_delivery do
    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: subscribe(),
        channel_config_id: 123,
        conversation_id: "conversation",
        events: %{
          typing: "response.typing",
          message_create: "response.message.create",
          message_edit: "response.message.edit",
          message_complete: "response.message.complete",
          message_failed: "response.message.failed",
          message_step: "response.message.step",
          status: "response.status",
          error: "response.error"
        }
      })

    delivery
  end

  defp subscribe do
    topic = "identity:#{Ecto.UUID.generate()}"
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, topic)
    topic
  end
end
