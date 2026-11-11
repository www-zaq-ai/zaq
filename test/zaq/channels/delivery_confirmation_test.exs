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

  test "each confirmed message is recorded separately even when overall delivery is partial" do
    parts =
      for index <- 0..1,
          do: %{
            confirmation: :confirmed,
            message_id: "post-#{index}",
            body: "part #{index}",
            delivery_part_index: index,
            thread_id: "root"
          }

    report = %{confirmation: :partial, messages: parts, failed_files: [%{filename: "failed.txt"}]}

    for part <- parts do
      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.request.receipt == part
        assert event.request.outgoing.body == part.body
        assert event.request.outgoing.attachments == []
        %{event | response: {:ok, part}}
      end)
    end

    assert {:ok, ^report} =
             DeliveryConfirmation.record({:ok, report}, outgoing(),
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "SMTP selection filters transient source Records without inventing provider attachment evidence" do
    attachments = [
      %Record{id: "failed", kind: :file, content: "failed"},
      %Record{
        id: "sent",
        kind: :file,
        content: "sent",
        materialization_handle: "original-handle",
        path: "/private/source",
        raw: %{token: "private credential"},
        attributes: %{"materialization_source" => %{"file_id" => "private source locator"}}
      }
    ]

    outgoing = %{outgoing() | attachments: attachments}

    for partial? <- [false, true] do
      receipt = %{
        confirmation: :confirmed,
        message_id: "smtp-id",
        body: "answer",
        delivered_attachment_indices: [1, 1, -1, 50]
      }

      report = if partial?, do: %{confirmation: :partial, messages: [receipt]}, else: receipt

      request = capture_confirmation(report, outgoing)

      assert outgoing.attachments == attachments

      assert [%Record{id: "sent", content: nil, materialization_handle: "original-handle"}] =
               request.outgoing.attachments

      refute Map.has_key?(request.receipt, :delivered_attachment_indices)
      assert request.receipt.attachments == [%{"kind" => "file"}]
      refute inspect(request.receipt.attachments) =~ "private"
    end
  end

  property "explicit attachment indices persist only selected metadata in original order" do
    check all(
            count <- integer(1..8),
            indices <-
              list_of(one_of([integer(-5..12), constant(nil), constant("0"), constant(0.0)]),
                max_length: 20
              ),
            partial? <- boolean()
          ) do
      outgoing = %{
        outgoing()
        | attachments:
            for index <- 0..(count - 1) do
              %Record{
                id: to_string(index),
                name: "file-#{index}",
                kind: :file,
                content: "private bytes",
                materialization_handle: "private handle",
                path: "/private/path",
                raw: %{token: "private credential"},
                attributes: %{"materialization_source" => %{"file_id" => "private locator"}}
              }
            end
      }

      selected =
        indices
        |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 < count))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&%{"name" => "file-#{&1}", "kind" => "file"})

      receipt = %{
        confirmation: :confirmed,
        message_id: "smtp-id",
        delivered_attachment_indices: indices
      }

      report = if partial?, do: %{confirmation: :partial, messages: [receipt]}, else: receipt

      request = capture_confirmation(report, outgoing)

      assert request.receipt.attachments == selected

      assert Enum.map(request.outgoing.attachments, & &1.id) ==
               Enum.map(selected, &String.replace_prefix(&1["name"], "file-", ""))

      refute Map.has_key?(request.receipt, :delivered_attachment_indices)
      refute Jason.encode!(request.receipt.attachments) =~ "private"
    end
  end

  test "explicit provider attachment evidence takes precedence over selected source metadata" do
    outgoing = %{
      outgoing()
      | attachments: [%Record{id: "source-file", kind: :file}]
    }

    provider_metadata = %{
      "id" => "delivered-file",
      "attributes" => %{"materialization_source" => %{"file_id" => "delivered-provider-file"}}
    }

    for evidence <- [[], [provider_metadata]] do
      receipt = %{
        confirmation: :confirmed,
        message_id: "provider-id",
        delivered_attachment_indices: [0],
        attachments: evidence
      }

      request = capture_confirmation(receipt, outgoing)

      assert request.receipt.attachments == evidence
    end
  end

  test "an unsplit partial receipt preserves the original assistant identity and canonical body" do
    outgoing = %{
      outgoing()
      | body: "Original **answer**",
        metadata: %{
          assistant_message_id: "assistant-id",
          persisted_assistant_message_id: "assistant-id"
        }
    }

    receipt = %{
      confirmation: :confirmed,
      message_id: "smtp-id",
      thread_id: "root",
      delivered_attachment_indices: []
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.request.outgoing.body == "Original **answer**"
      assert event.request.outgoing.metadata == outgoing.metadata
      assert event.request.outgoing.attachments == []
      refute Map.has_key?(event.request.receipt, :body)
      %{event | response: {:ok, Map.put(event.request.receipt, :history_capture, :stored)}}
    end)

    assert {:ok, %{messages: [%{history_capture: :stored}]}} =
             DeliveryConfirmation.record(
               {:ok, %{confirmation: :partial, messages: [receipt]}},
               outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
  end

  test "malformed SMTP selection cannot confirm additional source Records" do
    outgoing = %{
      outgoing()
      | attachments: [%Record{id: "failed", kind: :file, content: "private"}]
    }

    receipt = %{
      confirmation: :confirmed,
      message_id: "smtp-id",
      delivered_attachment_indices: :invalid
    }

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.request.outgoing.attachments == []
      assert event.request.receipt.attachments == []
      %{event | response: {:ok, event.request.receipt}}
    end)

    assert {:ok, _} =
             DeliveryConfirmation.record({:ok, receipt}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )
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
    assert_recording_failure(fn -> raise "engine unavailable" end)
  end

  test "catches a dispatch exit while preserving a confirmed receipt" do
    assert_recording_failure(fn -> exit(:engine_unavailable) end)
  end

  defp capture_confirmation(report, outgoing) do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(self(), {:confirmed_request, event.request})
      %{event | response: {:ok, event.request.receipt}}
    end)

    assert {:ok, _} =
             DeliveryConfirmation.record({:ok, report}, outgoing,
               delivery_node_router: Zaq.NodeRouterMock
             )

    assert_received {:confirmed_request, request}
    request
  end

  defp assert_recording_failure(fail) do
    receipt = %{confirmation: :confirmed, message_id: "external-1"}
    outgoing = outgoing()
    owner = self()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(owner, {:dispatch_event, event})
      fail.()
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
