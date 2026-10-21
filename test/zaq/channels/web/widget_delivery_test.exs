defmodule Zaq.Channels.Web.WidgetDeliveryTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ErrorMessage
  alias Zaq.Channels.MessageFormatter
  alias Zaq.Channels.Web.{Delivery, Response, SyncReply}
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  defmodule PortalUrl do
    def credentials, do: "https://zaq.example.test/people/credentials"
  end

  setup do
    topic = "widget:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    {:ok, delivery} =
      Delivery.new(%{
        consumer: :widget,
        topic: topic,
        channel_config_id: 1,
        conversation_id: "chat",
        message_id: "assistant",
        events:
          Map.new(
            [
              :typing,
              :message_create,
              :message_edit,
              :message_step,
              :message_complete,
              :message_failed,
              :error,
              :status
            ],
            &{&1, &1}
          )
      })

    incoming =
      Incoming.new(%{
        content: "Question",
        provider: :web_widget,
        channel_id: "chat",
        message_id: "user",
        metadata: %{request_id: "request"},
        routing_context: %{attributes: %{"web_delivery" => Delivery.reference(delivery)}}
      })

    %{delivery: delivery, incoming: incoming}
  end

  test "native start creates an independent assistant stream; prior statuses create nothing", %{
    incoming: incoming
  } do
    assert {:ok, %{message_id: nil}} = status(incoming, :answering, "Pre-admission")
    refute_received {:web_response, _, _}

    assert {:ok, %{message_id: "assistant"}} = status(incoming, :execution_started, "Preparing")
    assert_received {:web_response, "typing", %Response{payload: %{active: true}}}

    assert_received {:web_response, "message_create",
                     %Response{
                       protocol_version: 2,
                       message_id: "assistant",
                       conversation_id: "chat"
                     }}

    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :answering, "Snapshot", :stream_delta)

    assert_received {:web_response, "message_edit",
                     %Response{message_id: "assistant", payload: %{body: "Snapshot"}}}
  end

  test "widget receives allowlisted streamed and terminal tool snapshots", %{incoming: incoming} do
    running = %{
      "id" => "lookup",
      "kind" => "tool",
      "name" => "lookup",
      "label" => "lookup",
      "sequence" => 1,
      "state" => "running"
    }

    status(incoming, :execution_started, "Preparing")

    assert {:ok, _} =
             WebBridge.upsert_message(
               nil,
               %{
                 routing_context: incoming.routing_context,
                 request_id: "request",
                 message_id: "assistant",
                 body: "Working",
                 update_intent: :tool_call,
                 intent_meta: %{stage: :tool_call},
                 tool_steps: [Map.put(running, "params", "private")]
               },
               %{}
             )

    assert_receive {:web_response, "message_step", %Response{payload: %{tool_steps: [^running]}}}

    settled = Map.merge(running, %{"state" => "unknown", "duration_ms" => 12})
    outgoing = Outgoing.from_pipeline_result(incoming, %{answer: "done", tool_steps: [settled]})
    assert {:ok, _} = WebBridge.send_reply(outgoing, %{})

    assert_receive {:web_response, "message_complete",
                    %Response{payload: %{tool_steps: [^settled]}}}
  end

  test "queued input settles submission without any assistant answer", %{incoming: incoming} do
    status(incoming, :submission_accepted, "Accepted")

    assert_received {:web_response, "status",
                     %Response{message_id: nil, payload: %{accepted: true}}}

    refute_received {:web_response, "message_create", _}

    queued =
      Outgoing.from_pipeline_result(incoming, %{
        answer: "",
        error: false,
        execution_disposition: "queued",
        root_request_id: "private"
      })

    assert {:ok, %{delivered: false}} = WebBridge.send_reply(queued, %{})
    refute_received {:web_response, "message_complete", _}
  end

  test "credential failure before streaming preserves recovery text and starts a failed message",
       %{
         incoming: incoming
       } do
    reason = %{reason: :personal_credential_required}

    outgoing =
      incoming
      |> Outgoing.from_pipeline_result(%{
        answer: ErrorMessage.from_reason(reason),
        error: true,
        error_recovery: ErrorMessage.recovery_for(reason)
      })
      |> MessageFormatter.format_outgoing(people_portal_url_module: PortalUrl)

    assert outgoing.body =~ "https://zaq.example.test/people/credentials"
    refute outgoing.metadata[:status_message_id]

    assert {:ok, %{delivered: true, confirmation: :confirmed}} =
             WebBridge.send_reply(outgoing, %{})

    assert_receive {:web_response, "typing", %Response{payload: %{active: true}}}

    assert_receive {:web_response, "message_create",
                    %Response{
                      message_id: "assistant",
                      request_id: "request",
                      payload: %{body: ""}
                    }}

    assert_receive {:web_response, "typing", %Response{payload: %{active: false}}}

    assert_receive {:web_response, "message_failed",
                    %Response{
                      message_id: "assistant",
                      request_id: "request",
                      conversation_id: "chat",
                      payload: payload
                    }}

    assert payload.body == outgoing.body
    assert payload.error
    refute Map.has_key?(payload, :error_recovery)
    refute_received {:web_response, "error", _}
    refute_received {:web_response, "message_complete", _}
  end

  test "activity projection never exposes reasoning or internal submission disposition", %{
    incoming: incoming
  } do
    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :retrieving, "Private reasoning and arguments")
    assert_received {:web_response, "message_step", %Response{payload: payload}}
    assert payload.label == "Retrieving information"
    refute Map.has_key?(payload, :body)
    refute Map.has_key?(payload, :execution_disposition)
  end

  test "synchronous delivery returns an early failure body instead of a submission rejection", %{
    delivery: delivery,
    incoming: incoming
  } do
    body = "Please connect your personal credentials."

    dispatch = fn private_delivery ->
      incoming =
        put_in(
          incoming.routing_context.attributes["web_delivery"],
          Delivery.reference(private_delivery)
        )

      incoming
      |> Outgoing.from_pipeline_result(%{answer: body, error: true})
      |> WebBridge.send_reply(%{})
    end

    assert %Response{type: :message_failed, message_id: "assistant", payload: %{body: ^body}} =
             SyncReply.run(delivery, "request", dispatch, 1_000)

    refute_received {:web_response, _, _}
  end

  test "persistence failure ends its started stream without exposing exception details", %{
    incoming: incoming
  } do
    incoming = put_in(incoming.metadata[:status_message_id], "assistant")
    status(incoming, :failed, "Private storage exception")
    assert_received {:web_response, "typing", %Response{payload: %{active: false}}}

    assert_received {:web_response, "message_failed",
                     %Response{
                       message_id: "assistant",
                       payload: %{body: "Unable to save the response"}
                     }}

    refute_received {:web_response, "message_complete", _}
  end

  defp status(incoming, stage, body, intent \\ :status) do
    WebBridge.upsert_message(
      nil,
      %{
        routing_context: incoming.routing_context,
        request_id: "request",
        message_id: incoming.metadata[:status_message_id],
        body: body,
        update_intent: intent,
        intent_meta: %{stage: stage}
      },
      %{}
    )
  end
end
