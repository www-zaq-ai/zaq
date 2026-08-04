defmodule Zaq.Channels.JidoChatBridgeAttachmentsTest do
  # Covers the inbound-media half of the bridge: what `to_internal/2` builds out of
  # `Jido.Chat.Media`, and what `materialize_inbound_attachment/1` asks the provider for.
  # Needs the sandbox because resolving the provider token reads the channel config.
  use Zaq.DataCase, async: false

  alias Jido.Chat
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event

  defmodule StubMedia do
    @moduledoc false

    def download_file(file_ref, opts) do
      send(self(), {:download, file_ref, opts})
      Process.get(:download_response, {:ok, "bytes"})
    end
  end

  defmodule NoDownloadMedia do
    @moduledoc false
    def capabilities, do: %{}
  end

  defp put_media_module(module) do
    channels = Application.get_env(:zaq, :channels, %{})
    telegram = Map.get(channels, :telegram, %{})
    updated = Map.put(channels, :telegram, Map.put(telegram, :media, module))
    Application.put_env(:zaq, :channels, updated)
    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
  end

  defp media(attrs) do
    Chat.Media.new(Map.merge(%{kind: :image, url: "telegram://file/abc"}, attrs))
  end

  defp incoming(attrs) do
    struct!(
      %Chat.Incoming{
        text: "look at this",
        external_room_id: "room-1",
        external_message_id: "msg-1",
        media: []
      },
      attrs
    )
  end

  describe "to_internal/2 attachments" do
    test "a message with no media carries an empty attachment page" do
      msg = JidoChatBridge.to_internal(incoming(%{}), :telegram)

      assert %RecordPage{resource_type: :attachment, records: []} = msg.attachments
    end

    test "media becomes an unmaterialized record with a channels-bound event" do
      photo = media(%{filename: "photo.jpg", media_type: "image/jpeg", size_bytes: 120})
      msg = JidoChatBridge.to_internal(incoming(%{media: [photo]}), :telegram)

      assert [%Record{} = record] = msg.attachments.records
      assert record.content == nil
      assert record.kind == :file
      assert record.name == "photo.jpg"
      assert record.mime_type == "image/jpeg"
      assert record.size == 120
      assert record.attributes["provider"] == "telegram"
      assert record.attributes["media_kind"] == "image"
      assert record.attributes["file_ref"] == "telegram://file/abc"

      assert %Event{} = event = record.materializing_event
      assert event.opts[:action] == :materialize_inbound_attachment
      assert event.next_hop.destination == :channels
      assert event.request == %{file_ref: "telegram://file/abc", provider: "telegram"}
    end

    test "a caption-less photo keeps its attachment and leaves content untouched" do
      msg =
        JidoChatBridge.to_internal(
          incoming(%{text: nil, media: [media(%{media_type: "image/jpeg"})]}),
          :telegram
        )

      assert msg.content == nil
      assert length(msg.attachments.records) == 1
    end

    test "several media on one message each get their own record" do
      msg =
        JidoChatBridge.to_internal(
          incoming(%{media: [media(%{filename: "a.jpg"}), media(%{filename: "b.jpg"})]}),
          :telegram
        )

      assert ["a.jpg", "b.jpg"] = Enum.map(msg.attachments.records, & &1.name)
    end

    test "a nameless photo gets a name derived from its kind and mime type" do
      msg =
        JidoChatBridge.to_internal(
          incoming(%{media: [media(%{filename: nil, media_type: "image/jpeg"})]}),
          :telegram
        )

      assert [%Record{name: name}] = msg.attachments.records
      assert name =~ ~r/^image-0\./
    end

    test "a nameless photo with no mime type still gets a name" do
      msg =
        JidoChatBridge.to_internal(
          incoming(%{media: [media(%{filename: nil, media_type: nil})]}),
          :telegram
        )

      assert [%Record{name: "image-0"}] = msg.attachments.records
    end

    test "media with no provider reference cannot be materialized" do
      msg =
        JidoChatBridge.to_internal(
          incoming(%{media: [media(%{url: nil, filename: "x.jpg"})]}),
          :telegram
        )

      assert [%Record{materializing_event: nil, id: "telegram:attachment:0"}] =
               msg.attachments.records
    end
  end

  describe "materialize_inbound_attachment/1" do
    test "downloads through the provider's media module and answers base64" do
      put_media_module(StubMedia)
      Process.put(:download_response, {:ok, "hi"})

      assert {:ok, %{record: %Record{} = record}} =
               JidoChatBridge.materialize_inbound_attachment(%{
                 file_ref: "telegram://file/abc",
                 provider: "telegram"
               })

      assert record.content == Base.encode64("hi")
      assert record.attributes["encoding"] == "base64"
      assert record.size == 2
      assert_received {:download, "telegram://file/abc", _opts}
    end

    test "passes the channel token to the provider" do
      put_media_module(StubMedia)

      JidoChatBridge.materialize_inbound_attachment(%{
        file_ref: "telegram://file/abc",
        provider: "telegram"
      })

      assert_received {:download, _ref, opts}
      assert Keyword.has_key?(opts, :token)
    end

    test "surfaces the provider's download failure" do
      put_media_module(StubMedia)
      Process.put(:download_response, {:error, :file_gone})

      assert {:error, :file_gone} =
               JidoChatBridge.materialize_inbound_attachment(%{
                 file_ref: "telegram://file/abc",
                 provider: "telegram"
               })
    end

    test "a provider whose media module cannot download is unsupported" do
      put_media_module(NoDownloadMedia)

      assert {:error, :unsupported} =
               JidoChatBridge.materialize_inbound_attachment(%{
                 file_ref: "telegram://file/abc",
                 provider: "telegram"
               })
    end

    test "a provider with no media module at all is unsupported" do
      assert {:error, :unsupported} =
               JidoChatBridge.materialize_inbound_attachment(%{
                 file_ref: "x://y",
                 provider: "mattermost"
               })
    end

    test "an unknown provider is unsupported rather than a crash" do
      assert {:error, :unsupported} =
               JidoChatBridge.materialize_inbound_attachment(%{
                 file_ref: "x://y",
                 provider: "nope"
               })
    end

    test "a request with no file reference is rejected" do
      assert {:error, :file_ref_required} =
               JidoChatBridge.materialize_inbound_attachment(%{provider: "telegram"})
    end
  end
end
