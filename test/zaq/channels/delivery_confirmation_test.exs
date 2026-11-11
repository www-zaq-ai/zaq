defmodule Zaq.Channels.DeliveryConfirmationTest do
  use ExUnit.Case, async: true

  import Mox

  alias Zaq.Channels.DeliveryConfirmation
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.EventHop

  setup :verify_on_exit!

  test "rescues a dispatch exception while preserving a confirmed receipt" do
    receipt = %{confirmation: :confirmed, message_id: "external-1"}
    outgoing = outgoing()
    owner = self()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:dispatch_event, event})
      raise "engine unavailable"
    end)

    assert DeliveryConfirmation.record({:ok, receipt}, outgoing,
             delivery_node_router: Zaq.NodeRouterMock
           ) ==
             {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}

    assert receipt == %{confirmation: :confirmed, message_id: "external-1"}

    assert_received {:dispatch_event,
                     %Event{
                       request: %{receipt: ^receipt, outgoing: routed},
                       next_hop: %EventHop{destination: :engine},
                       opts: [action: :record_delivery_confirmation]
                     }}

    assert routed.body == outgoing.body
    assert routed.metadata == %{user_message_id: "u-1", assistant_message_id: "a-1"}
  end

  test "catches a dispatch exit while preserving a confirmed receipt" do
    receipt = %{confirmation: :confirmed, message_id: "external-1"}
    outgoing = outgoing()
    owner = self()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:dispatch_event, event})
      exit(:engine_unavailable)
    end)

    assert DeliveryConfirmation.record({:ok, receipt}, outgoing,
             delivery_node_router: Zaq.NodeRouterMock
           ) ==
             {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}

    assert receipt == %{confirmation: :confirmed, message_id: "external-1"}

    assert_received {:dispatch_event,
                     %Event{
                       request: %{receipt: ^receipt, outgoing: routed},
                       next_hop: %EventHop{destination: :engine},
                       opts: [action: :record_delivery_confirmation]
                     }}

    assert routed.body == outgoing.body
    assert routed.metadata == %{user_message_id: "u-1", assistant_message_id: "a-1"}
  end

  test "reports an ambiguous timeout with only persisted identifiers and safe reason codes" do
    outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :record_delivery_observation
      assert event.opts[:confidential]

      assert event.request == %{
               user_message_id: "u-1",
               assistant_message_id: "a-1",
               channel_config_id: 12,
               outcome: :unconfirmed,
               reason: :timeout
             }

      %{event | response: {:ok, :recorded}}
    end)

    assert {:error, :timeout} =
             DeliveryConfirmation.record({:error, :timeout}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "a real Mattermost HTTP rejection is definite and does not expose its response body" do
    outgoing = %{outgoing() | provider: :mattermost, routing_context: %{channel_config_id: 12}}
    result = {:error, {403, %{"message" => "private provider detail"}}}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.request.outcome == :failed
      assert event.request.reason == :rejected
      assert event.request.provider_code == 403
      refute inspect(event.request) =~ "private provider detail"
      event
    end)

    assert DeliveryConfirmation.record(result, outgoing, delivery_node_router: Zaq.NodeRouterMock) ==
             result
  end

  for reason <- [:channel_disabled, :channel_archived, :channel_config_not_found] do
    test "pre-send #{reason} is a definite configuration failure" do
      outgoing = %{outgoing() | routing_context: %{channel_config_id: 12}}
      response = {:error, unquote(reason)}

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:configuration_observation, event})
        %{event | response: {:ok, :recorded}}
      end)

      assert DeliveryConfirmation.record(response, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             ) == response

      assert_received {:configuration_observation, event}
      assert event.opts[:action] == :record_delivery_observation
      assert event.opts[:confidential]

      assert event.request == %{
               user_message_id: "u-1",
               assistant_message_id: "a-1",
               channel_config_id: 12,
               outcome: :failed,
               reason: :missing_configuration
             }
    end
  end

  test "unsuccessful reporting preserves errors and never creates evidence for a reserved-only UUID" do
    expect(Zaq.NodeRouterMock, :dispatch, fn _ -> exit(:engine_unavailable) end)

    assert {:error, :timeout} =
             DeliveryConfirmation.record({:error, :timeout}, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )

    outgoing = %{
      outgoing()
      | metadata: %{assistant_message_id: "reserved", persisted_assistant_message_id: nil}
    }

    assert {:error, :timeout} =
             DeliveryConfirmation.record({:error, :timeout}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  defp outgoing do
    %Outgoing{
      body: "delivered",
      channel_id: "channel-1",
      provider: :test,
      metadata: %{
        user_message_id: "u-1",
        assistant_message_id: "a-1",
        trace: "private"
      }
    }
  end
end
