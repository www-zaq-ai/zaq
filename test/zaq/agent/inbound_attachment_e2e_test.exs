defmodule Zaq.Agent.InboundAttachmentE2ETest do
  # The whole inbound-image path, hop by hop, with nothing between them stubbed: a provider
  # message becomes an `%Incoming{}`, the notice tells the model what call to make, that call
  # goes through the real `Zaq.Channels.Api` to the real bridge, and the bytes come back as a
  # content part. Only the Telegram adapter's network call is faked.
  #
  # Each hop has its own unit tests; what those cannot catch is the handles drifting — a
  # notice naming a provider the tool does not answer to, or an id the message cannot be
  # searched by. Both are silent: the model simply never sees the image.
  #
  # Needs the sandbox because resolving the provider token reads the channel config.
  use Zaq.DataCase, async: false

  alias Jido.Chat
  alias Zaq.Agent.Tools.Messages.DownloadAttachment
  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Ingestion.Api, as: IngestionApi

  @png <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0>>

  defmodule StubAdapter do
    @moduledoc false

    def fetch_media(file_ref, _opts) do
      send(self(), {:fetch_media, file_ref})
      Process.get(:media_response)
    end
  end

  # Stands in for `NodeRouter` only as far as the wire: every event it is handed is executed
  # by the module that would really have received it on the other node.
  defmodule RealChannelsRouter do
    @moduledoc false

    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:dispatch, event.next_hop.destination, opts[:action]})

      case event.next_hop.destination do
        :channels -> Api.handle_event(event, opts[:action], %{})
        :ingestion -> IngestionApi.handle_event(event, opts[:action], nil)
      end
    end
  end

  setup do
    channels = Application.get_env(:zaq, :channels, %{})
    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
    Process.put(:media_response, {:ok, @png})

    # An attachment is now addressed as a document, so the fetch resolves the channel's config
    # the way any data source read does. A Telegram channel that receives messages at all has
    # this row in production.
    {:ok, _config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Telegram",
        provider: "telegram",
        kind: "retrieval",
        url: "https://api.telegram.org",
        token: "secret",
        enabled: true
      })
      |> Repo.insert()

    :ok
  end

  defp put_adapter(module) do
    channels = Application.get_env(:zaq, :channels, %{})
    telegram = Map.get(channels, :telegram, %{})

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :telegram, %{telegram | adapter: module})
    )
  end

  defp chat_message(media_attrs \\ %{}) do
    media =
      Chat.Media.new(
        Map.merge(%{kind: :image, url: "telegram://file/abc", filename: "photo.png"}, media_attrs)
      )

    %Chat.Incoming{
      text: "what does this say?",
      external_room_id: "room-1",
      external_message_id: "msg-1",
      media: [media]
    }
  end

  defp context(modalities),
    do: %{node_router: RealChannelsRouter, input_modalities: modalities}

  describe "a photo sent on Telegram, read by a vision model" do
    setup do
      put_adapter(StubAdapter)
      :ok
    end

    test "travels from provider message to image content part" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert [%Record{name: "photo.png"}] = Incoming.attachment_records(incoming)

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert [%ReqLLM.Message.ContentPart{type: :image} = part] = payload.__content_parts__
      assert part.data == @png
      assert part.media_type == "image/png"

      assert_received {:dispatch, :channels, :data_source_download_document}
      assert_received {:fetch_media, "telegram://file/abc"}
    end

    test "the file is discoverable from the tool alone, with nothing announcing it" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)
      context = Map.put(context([:text, :image]), :incoming, incoming)

      # Nothing in the message names the file — the caption is all the model is given.
      assert incoming.content == "what does this say?"

      assert {:ok, %{attachments: [%{attachment_id: id, name: "photo.png"}]}} =
               DownloadAttachment.run(%{}, context)

      refute_received {:fetch_media, _ref}

      assert {:ok, payload} = DownloadAttachment.run(%{attachment_id: id}, context)
      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
      assert_received {:fetch_media, "telegram://file/abc"}
    end

    test "the caption the person typed is never touched by any of it" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert incoming.content == "what does this say?"
      assert Incoming.attachment_records(incoming) != []
    end

    test "the bytes do not also travel as base64 in the JSON payload" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert payload.record.content == nil
      assert payload.record.attributes["content_delivered_as"] == "image"
    end

    test "the name from the provider message survives materialization" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([]), :incoming, incoming)
               )

      assert payload.record.name == "photo.png"
    end

    test "a photo Telegram declares no type for is sniffed from the bytes" do
      incoming =
        JidoChatBridge.to_internal(
          chat_message(%{filename: nil, media_type: nil}),
          :telegram
        )

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert [%ReqLLM.Message.ContentPart{media_type: "image/png"}] = payload.__content_parts__
    end
  end

  describe "the same photo, on an agent whose model cannot see" do
    setup do
      put_adapter(StubAdapter)
      :ok
    end

    test "is refused after the fetch when the provider declared no type" do
      incoming = JidoChatBridge.to_internal(chat_message(%{media_type: nil}), :telegram)

      assert {:ok, %{refused: message}} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text]), :incoming, incoming)
               )

      assert message =~ "cannot read image"
    end

    test "is refused before the fetch when the provider declared the type" do
      incoming = JidoChatBridge.to_internal(chat_message(%{media_type: "image/png"}), :telegram)

      assert {:ok, %{refused: _message}} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text]), :incoming, incoming)
               )

      refute_received {:fetch_media, _ref}
    end
  end

  describe "failures on the way" do
    test "a provider download failure is reported, not swallowed" do
      put_adapter(StubAdapter)
      Process.put(:media_response, {:error, :file_gone})
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:error, message} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert message =~ "file_gone"
    end

    test "an attachment with no provider reference cannot be fetched" do
      incoming = JidoChatBridge.to_internal(chat_message(%{url: nil}), :telegram)

      assert [%Record{materializing_event: nil}] = Incoming.attachment_records(incoming)

      assert {:error, message} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert message =~ "cannot be fetched"
      refute_received {:dispatch, _destination, _action}
    end

    test "an id that names no attachment on this message is an error, not a crash" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:error, message} =
               DownloadAttachment.run(
                 %{attachment_id: "telegram://file/nope"},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert message =~ "no attachment"
    end

    test "a tool call with no message in context cannot reach an attachment" do
      assert {:error, message} =
               DownloadAttachment.run(
                 %{attachment_id: "telegram://file/abc"},
                 context([:text, :image])
               )

      assert message =~ "no attachment"
    end
  end

  defp attachment_id(%Incoming{} = incoming) do
    [%Record{id: id}] = Incoming.attachment_records(incoming)
    id
  end
end
