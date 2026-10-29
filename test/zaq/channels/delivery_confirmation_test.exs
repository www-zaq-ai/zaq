defmodule Zaq.Channels.DeliveryConfirmationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Channels.DeliveryConfirmation
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.EventHop

  setup :verify_on_exit!

  property "confirmation clears content while retaining attachment Records, handles, receipt and IDs" do
    check all(bytes <- binary(max_length: 2_048)) do
      receipt = %{
        confirmation: :confirmed,
        action: :created,
        message_id: "final-post",
        thread_id: "root"
      }

      ids = %{
        user_message_id: "u-1",
        assistant_message_id: "a-1",
        persisted_assistant_message_id: "stored-1"
      }

      attachments = [
        %Record{
          id: "file",
          kind: :file,
          content: bytes,
          name: "private.bin",
          materialization_handle: "materialized-file-handle",
          path: "/private/original",
          raw: %{token: "private"}
        },
        %Record{
          id: "lazy",
          kind: :file,
          materialization_handle: "private-handle",
          path: "/private/lazy"
        }
      ]

      outgoing = %{
        outgoing()
        | attachments: attachments,
          metadata:
            Map.merge(ids, %{
              "attachments" => attachments,
              attachments: attachments,
              trace: "private"
            })
      }

      [materialized, lazy] = attachments
      expected = %{outgoing | attachments: [%{materialized | content: nil}, lazy], metadata: ids}

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:projected_confirmation, event})
        %{event | response: {:ok, receipt}}
      end)

      assert {:ok, ^receipt} =
               DeliveryConfirmation.record({:ok, receipt}, outgoing,
                 delivery_node_router: Zaq.NodeRouterMock
               )

      assert_received {:projected_confirmation, event}
      assert event.request == %{receipt: receipt, outgoing: expected}
      assert event.next_hop.destination == :engine
      assert event.opts == [action: :record_delivery_confirmation]
      assert outgoing.attachments == attachments
    end
  end

  test "unconfirmed transport outcomes pass through without dispatching a recording event" do
    for response <- [
          {:error, :preparation_failed},
          {:error, :timeout},
          {:error, %Req.TransportError{reason: :timeout}},
          {:ok, %{message_id: "unconfirmed"}}
        ] do
      assert DeliveryConfirmation.record(response, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             ) == response
    end
  end

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
