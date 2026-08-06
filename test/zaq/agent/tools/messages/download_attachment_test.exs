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

    def dispatch(%Event{opts: [action: :attachment_destination]} = event) do
      send(self(), {:destination, event.request.provider})
      %{event | response: Process.get(:destination_response, {:ok, %{destination: nil}})}
    end

    def dispatch(%Event{request: %{provider: provider, params: params}} = event) do
      send(self(), {:create_file, provider, params})

      %{
        event
        | response:
            Process.get(:create_response, {:ok, %{record: %Record{id: "doc-7", kind: :file}}})
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

  describe "keeping a copy" do
    defp keeps_files_at(path) do
      Process.put(:destination_response, {:ok, %{destination: %{provider: "disk", path: path}}})
    end

    test "a channel that keeps nothing writes nothing" do
      assert {:ok, _payload} = run(context(record(), %{input_modalities: [:text, :image]}))

      assert_received {:destination, "telegram"}
      refute_received {:create_file, _provider, _params}
    end

    test "a channel with a destination gets the bytes written there" do
      keeps_files_at("media/attachments/telegram")

      assert {:ok, _payload} = run(context(record(), %{input_modalities: [:text, :image]}))

      assert_received {:create_file, "disk", params}
      assert params["path"] == "media/attachments/telegram"
      assert params["name"] == "photo.png"
      assert params["content"] == Base.encode64("PNGBYTES")
      assert params["encoding"] == "base64"
    end

    test "the stored document id travels back on the record" do
      keeps_files_at("media/attachments/telegram")

      assert {:ok, payload} = run(context(record(), %{input_modalities: []}))

      assert payload.record.attributes["stored_document_id"] == "doc-7"
    end

    test "the destination is asked for by the channel named on the fetching event" do
      assert {:ok, _payload} = run(context(record(), %{input_modalities: []}))

      assert_received {:destination, "telegram"}
    end

    test "a failed write does not cost the read" do
      keeps_files_at("media/attachments/telegram")
      Process.put(:create_response, {:error, :volume_gone})

      assert {:ok, payload} = run(context(record(), %{input_modalities: [:text, :image]}))

      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
      refute Map.has_key?(payload.record.attributes, "stored_document_id")
    end

    test "a channels node that cannot answer means nothing is kept" do
      Process.put(:destination_response, {:error, :node_down})

      assert {:ok, payload} = run(context(record(), %{input_modalities: [:text, :image]}))

      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
      refute_received {:create_file, _provider, _params}
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
