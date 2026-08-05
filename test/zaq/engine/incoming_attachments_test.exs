defmodule Zaq.Engine.IncomingAttachmentsTest do
  # The channels hop is stubbed at the router: these assert what the engine asks channels to
  # store and what the agent ends up reading, never the storage itself.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Zaq.Contracts.Record
  alias Zaq.Engine.IncomingAttachments
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  defmodule StubRouter do
    @moduledoc false

    def dispatch(%Event{} = event) do
      send(self(), {:dispatch, event.next_hop.destination, event.opts[:action], event.request})
      %{event | response: Process.get(:stub_response, {:error, :no_stub})}
    end
  end

  defp stub(response), do: Process.put(:stub_response, response)

  defp attachment(attrs \\ %{}) do
    struct!(
      %Record{
        id: "telegram://file/abc",
        kind: :file,
        name: "photo.jpg",
        mime_type: "image/jpeg",
        materializing_event:
          Event.new(%{file_ref: "telegram://file/abc"}, :channels,
            opts: [action: :materialize_inbound_attachment]
          )
      },
      attrs
    )
  end

  defp stored(id \\ "42", name \\ "photo.jpg") do
    %Record{id: id, kind: :file, name: name, mime_type: "image/jpeg"}
  end

  defp incoming(attrs \\ %{}) do
    Incoming.new(
      Map.merge(
        %{
          content: "what does this say?",
          channel_id: "room-1",
          provider: :telegram,
          author_id: "555",
          message_id: "msg-1",
          attachments: [attachment()]
        },
        attrs
      )
    )
  end

  defp store(incoming), do: IncomingAttachments.store(incoming, node_router: StubRouter)

  describe "store/2" do
    setup do
      stub({:ok, %{record: stored()}})
      :ok
    end

    test "a message with no attachments is returned untouched" do
      msg = incoming(%{attachments: []})

      assert store(msg) == msg
      refute_received {:dispatch, _, _, _}
    end

    test "asks channels to persist each attachment with the sender's identity" do
      store(incoming())

      assert_received {:dispatch, :channels, :persist_inbound_attachment, request}
      assert %Record{} = request.record
      assert request.provider == :telegram
      assert request.author_id == "555"
      assert request.message_id == "msg-1"
    end

    test "swaps in the stored record so the agent sees a disk-backed handle" do
      msg = store(incoming())

      assert [%Record{id: "42"}] = Incoming.attachment_records(msg)
    end

    test "leaves the sender's own words untouched" do
      # The announcement is system context, derived from the records — putting it in
      # `content` would make it look like the person typed it.
      msg = store(incoming())

      assert msg.content == "what does this say?"
      refute msg.content =~ "download_document"
    end

    test "the notice names the tool and both arguments" do
      # A model shown only `provider: "disk"` refused, reasoning that a file someone sent is
      # not a data source. The line has to spell out the call.
      notice = incoming() |> store() |> Incoming.attachment_notice()

      assert notice =~ "photo.jpg (image/jpeg)"
      assert notice =~ "call the download_document tool"
      assert notice =~ ~s(provider="disk")
      assert notice =~ ~s(document_id="42")
    end

    test "a message with no attachments has no notice at all" do
      assert incoming(%{attachments: []}) |> store() |> Incoming.attachment_notice() == nil
    end

    test "every attachment gets its own line" do
      stub({:ok, %{record: stored()}})

      notice =
        incoming(%{attachments: [attachment(), attachment()]})
        |> store()
        |> Incoming.attachment_notice()

      assert notice |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "[att")) == 2
    end

    test "a storage failure is marked on the record and said plainly in the notice" do
      stub({:error, :volume_full})

      log = capture_log(fn -> send(self(), {:result, store(incoming())}) end)
      assert log =~ "Failed to store attachment"

      assert_received {:result, result}
      assert [%Record{attributes: %{"storage" => "failed"}}] = Incoming.attachment_records(result)
      assert Incoming.attachment_notice(result) =~ "could not be stored"
      assert result.content == "what does this say?"
    end

    test "a failed attachment keeps its original record rather than dropping it" do
      stub({:error, :volume_full})

      result = capture_log(fn -> send(self(), {:result, store(incoming())}) end)
      assert is_binary(result)

      assert_received {:result, msg}
      assert [%Record{id: "telegram://file/abc"}] = Incoming.attachment_records(msg)
    end

    test "an unexpected response is treated as a failure, not a success" do
      stub({:ok, :surprise})

      capture_log(fn -> send(self(), {:result, store(incoming())}) end)

      assert_received {:result, msg}
      assert Incoming.attachment_notice(msg) =~ "could not be stored"
    end

    test "a record with no mime type is still announced" do
      stub({:ok, %{record: %Record{id: "42", kind: :file, name: "notes"}}})
      notice = incoming() |> store() |> Incoming.attachment_notice()

      assert notice =~ "[attachment: notes —"
      assert notice =~ ~s(document_id="42")
    end

    test "a record with neither name nor mime type is announced as unnamed" do
      stub({:ok, %{record: %Record{id: "42", kind: :file}}})

      assert incoming() |> store() |> Incoming.attachment_notice() =~ "[attachment: unnamed —"
    end

    test "a record with only a mime type is announced by that" do
      stub({:ok, %{record: %Record{id: "42", kind: :file, mime_type: "audio/ogg"}}})

      assert incoming() |> store() |> Incoming.attachment_notice() =~
               "[attachment: unnamed (audio/ogg) —"
    end
  end

  describe "store/2 person identity" do
    test "passes the resolved person id when the message has one" do
      stub({:ok, %{record: stored()}})
      store(incoming(%{person: %{"id" => 7}}))

      assert_received {:dispatch, :channels, :persist_inbound_attachment, %{person_id: 7}}
    end

    test "passes a nil person id when identity was not resolved" do
      stub({:ok, %{record: stored()}})
      store(incoming())

      assert_received {:dispatch, :channels, :persist_inbound_attachment, %{person_id: nil}}
    end
  end
end
