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

  # The id the model is told to send back, read out of the notice rather than out of the
  # record — if the two ever disagree the tool call the model actually makes is this one.
  defp attachment_id_from_notice(notice) do
    [_, id] = Regex.run(~r|attachment_id="([^"]+)"|, notice)
    id
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
      notice = Incoming.attachment_notice(incoming)

      assert notice =~ "photo.png"
      assert notice =~ "download_attachment"

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id_from_notice(notice)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert [%ReqLLM.Message.ContentPart{type: :image} = part] = payload.__content_parts__
      assert part.data == @png
      assert part.media_type == "image/png"

      assert_received {:dispatch, :channels, :materialize_inbound_attachment}
      assert_received {:fetch_media, "telegram://file/abc"}
    end

    test "the caption the person typed is never touched by any of it" do
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert incoming.content == "what does this say?"
      assert Incoming.attachment_notice(incoming) != nil
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

    test "an attachment with no provider reference is described as unfetchable" do
      incoming = JidoChatBridge.to_internal(chat_message(%{url: nil}), :telegram)

      assert Incoming.attachment_notice(incoming) =~ "no way to fetch"

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

  # Reading a file and keeping a copy of it are one operation from the model's side, so the
  # whole of it runs here: channel config chosen in BO, bytes fetched from the provider, file
  # written by ingestion onto the volume that config names.
  describe "a channel configured to keep what it receives" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "zaq_attachment_e2e_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)

      original = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(original || [], volumes: %{"media" => root})
      )

      on_exit(fn ->
        File.rm_rf(root)

        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      put_adapter(StubAdapter)
      %{root: root}
    end

    defp configure_channel(settings) do
      {:ok, _config} =
        ChannelConfig.upsert_by_provider("telegram", %{
          name: "Telegram",
          kind: "retrieval",
          enabled: true,
          url: "https://api.telegram.org",
          token: "test-token",
          settings: settings
        })

      :ok
    end

    test "writes the photo onto the configured volume", %{root: root} do
      configure_channel(%{
        "attachments" => %{
          "persist" => true,
          "provider" => "disk",
          "path" => "media/attachments/telegram"
        }
      })

      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      assert File.read!(Path.join([root, "attachments", "telegram", "photo.png"])) == @png
      assert payload.record.attributes["stored_document_id"]
      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
    end

    test "a channel with no volume chosen keeps nothing", %{root: root} do
      configure_channel(%{})
      incoming = JidoChatBridge.to_internal(chat_message(), :telegram)

      assert {:ok, payload} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text, :image]), :incoming, incoming)
               )

      refute File.exists?(Path.join(root, "attachments"))
      refute Map.has_key?(payload.record.attributes, "stored_document_id")
      assert [%ReqLLM.Message.ContentPart{type: :image}] = payload.__content_parts__
    end

    test "a model that cannot see the image keeps no copy either", %{root: root} do
      configure_channel(%{
        "attachments" => %{
          "persist" => true,
          "provider" => "disk",
          "path" => "media/attachments/telegram"
        }
      })

      incoming = JidoChatBridge.to_internal(chat_message(%{media_type: "image/png"}), :telegram)

      assert {:ok, %{refused: _message}} =
               DownloadAttachment.run(
                 %{attachment_id: attachment_id(incoming)},
                 Map.put(context([:text]), :incoming, incoming)
               )

      refute File.exists?(Path.join(root, "attachments"))
    end
  end
end
