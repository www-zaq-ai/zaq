defmodule Zaq.Agent.Tools.Messages.DownloadAttachmentTest do
  # Unit-level: the record's materializing event is answered by a stub router, so these cover
  # the shapes the real channel path cannot produce. The real path — provider message through
  # to a content part — is `Zaq.Agent.InboundAttachmentE2ETest`.
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Messages.DownloadAttachment
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  defmodule StubRouter do
    @moduledoc false

    def dispatch(%Event{request: %{file_ref: file_ref}} = event) do
      send(self(), {:materialize, file_ref})

      %{
        event
        | response:
            Process.get(
              :materialize_response,
              {:ok,
               %{
                 record: %Record{
                   id: file_ref,
                   kind: :file,
                   name: Process.get(:fetched_name),
                   mime_type: "image/png",
                   content: Base.encode64("PNGBYTES"),
                   attributes: %{"encoding" => "base64"}
                 }
               }}
            )
      }
    end
  end

  defp record(attrs \\ %{}) do
    struct!(
      %Record{
        id: "telegram://file/abc",
        kind: :file,
        name: "photo.png",
        mime_type: nil,
        content: nil,
        materializing_event:
          Event.new(%{file_ref: "telegram://file/abc", provider: "telegram"}, :channels,
            opts: [action: :materialize_inbound_attachment]
          )
      },
      attrs
    )
  end

  defp context(record, overrides \\ %{}) do
    Map.merge(
      %{
        node_router: StubRouter,
        incoming: %Incoming{
          content: "look",
          channel_id: "ch1",
          provider: :telegram,
          attachments: %RecordPage{resource_type: :attachment, records: [record]}
        }
      },
      overrides
    )
  end

  defp run(context, attachment_id \\ "telegram://file/abc"),
    do: DownloadAttachment.run(%{attachment_id: attachment_id}, context)

  describe "listing what is attached" do
    test "an omitted id lists instead of fetching, and moves no bytes" do
      assert {:ok, %{attachments: [entry]}} = DownloadAttachment.run(%{}, context(record()))

      assert entry == %{
               attachment_id: "telegram://file/abc",
               name: "photo.png",
               mime_type: nil,
               size: nil,
               readable: true
             }

      refute_received {:materialize, _file_ref}
    end

    test "an explicit nil id lists too — the model omitting a value means the same thing" do
      assert {:ok, %{attachments: [_entry]}} =
               DownloadAttachment.run(%{attachment_id: nil}, context(record()))
    end

    test "the id it hands back is the one that reads the file" do
      context = context(record(), %{input_modalities: [:text, :image]})

      assert {:ok, %{attachments: [%{attachment_id: id}]}} = DownloadAttachment.run(%{}, context)
      assert {:ok, payload} = DownloadAttachment.run(%{attachment_id: id}, context)
      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
    end

    test "an attachment with no way to be fetched says so rather than costing a call" do
      assert {:ok, %{attachments: [entry]}} =
               DownloadAttachment.run(%{}, context(record(%{materializing_event: nil})))

      assert entry.readable == false
    end

    test "name, type and size travel so a file can be chosen without opening it" do
      record = record(%{name: "scan.pdf", mime_type: "application/pdf", size: 24_010})

      assert {:ok, %{attachments: [entry]}} = DownloadAttachment.run(%{}, context(record))
      assert %{name: "scan.pdf", mime_type: "application/pdf", size: 24_010} = entry
    end

    test "a message with nothing attached lists nothing" do
      context = %{
        node_router: StubRouter,
        incoming: %Incoming{content: "hi", channel_id: "ch1", provider: :telegram}
      }

      assert {:ok, %{attachments: []}} = DownloadAttachment.run(%{}, context)
    end

    test "a context with no message lists nothing rather than crashing" do
      assert {:ok, %{attachments: []}} = DownloadAttachment.run(%{}, %{node_router: StubRouter})
    end

    test "a context whose :incoming is not a message lists nothing" do
      assert {:ok, %{attachments: []}} =
               DownloadAttachment.run(%{}, %{node_router: StubRouter, incoming: :nope})
    end

    test "every attachment on the message is listed, in order" do
      records = [record(%{id: "a", name: "one.png"}), record(%{id: "b", name: "two.pdf"})]

      context = %{
        node_router: StubRouter,
        incoming: %Incoming{
          content: "look",
          channel_id: "ch1",
          provider: :telegram,
          attachments: %RecordPage{resource_type: :attachment, records: records}
        }
      }

      assert {:ok, %{attachments: [%{attachment_id: "a"}, %{attachment_id: "b"}]}} =
               DownloadAttachment.run(%{}, context)
    end
  end

  describe "reading an attachment" do
    test "dispatches the record's own event, not a data source download" do
      assert {:ok, payload} =
               run(context(record(), %{input_modalities: [:text, :image]}))

      assert [%ReqLLM.Message.ContentPart{type: :image} = part] = payload.__content_parts__
      assert part.data == "PNGBYTES"
      assert_received {:materialize, "telegram://file/abc"}
    end

    test "keeps the name the provider gave the fetched record over the inbound one" do
      Process.put(:fetched_name, "server-name.png")

      assert {:ok, payload} = run(context(record(), %{input_modalities: []}))

      assert payload.record.name == "server-name.png"
    end

    test "falls back to the inbound name when the fetched record has none" do
      assert {:ok, payload} = run(context(record(), %{input_modalities: []}))

      assert payload.record.name == "photo.png"
    end

    test "an unknown modality list attempts the fetch rather than assuming blindness" do
      assert {:ok, payload} = run(context(record(), %{input_modalities: []}))

      assert %Record{} = payload.record
      assert_received {:materialize, _file_ref}
    end

    test "context with no modalities at all still attempts the fetch" do
      assert {:ok, _payload} = run(context(record()))

      assert_received {:materialize, _file_ref}
    end
  end

  describe "a model that cannot read the modality" do
    test "is refused after the fetch when the channel declared no type" do
      assert {:ok, %{refused: message}} =
               run(context(record(), %{input_modalities: [:text]}))

      assert message =~ "cannot read image"
      assert_received {:materialize, _file_ref}
    end

    test "is refused before the fetch when the channel declared the type" do
      assert {:ok, %{refused: message}} =
               run(context(record(%{mime_type: "image/png"}), %{input_modalities: [:text]}))

      assert message =~ "photo.png"
      refute_received {:materialize, _file_ref}
    end
  end

  describe "failures" do
    test "surfaces the provider's failure rather than swallowing it" do
      Process.put(:materialize_response, {:error, :file_gone})

      assert {:error, message} = run(context(record(), %{input_modalities: [:text, :image]}))

      assert message =~ "Attachment download failed"
      assert message =~ "file_gone"
    end

    test "an unfetchable attachment names itself in the error" do
      assert {:error, message} = run(context(record(%{materializing_event: nil})))

      assert message =~ "photo.png cannot be fetched"
      refute_received {:materialize, _file_ref}
    end

    test "an unfetchable, unnamed attachment still errors readably" do
      assert {:error, message} =
               run(context(record(%{name: nil, materializing_event: nil})))

      assert message =~ "the attachment cannot be fetched"
    end

    test "an id naming no attachment on this message is an error, not a crash" do
      assert {:error, message} = run(context(record()), "telegram://file/nope")

      assert message =~ "no attachment"
    end

    test "a context with no message cannot reach an attachment" do
      assert {:error, message} = run(%{node_router: StubRouter})

      assert message =~ "no attachment"
    end

    test "a context whose :incoming is not a message cannot reach an attachment" do
      assert {:error, message} = run(%{node_router: StubRouter, incoming: %{not: "a message"}})

      assert message =~ "no attachment"
    end
  end
end
