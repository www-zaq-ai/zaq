defmodule Zaq.Channels.JidoChatBridge.MediaTest do
  use Zaq.DataCase, async: true

  alias Jido.Chat.Media
  alias Zaq.Channels.JidoChatBridge.Media, as: TargetMedia

  describe "build_records/3" do
    test "returns empty list for nil media" do
      assert TargetMedia.build_records(nil, :telegram, %{}) == []
    end

    test "returns empty list for empty media list" do
      assert TargetMedia.build_records([], :telegram, %{}) == []
    end

    test "creates stub record for a single file when download is unavailable" do
      media = [
        %Media{
          kind: :file,
          url: "telegram://file/abc123",
          filename: "doc.pdf",
          media_type: "application/pdf",
          size_bytes: 1024
        }
      ]

      [record] = TargetMedia.build_records(media, :telegram, %{})

      assert record.id == "telegram_telegram://file/abc123"
      assert record.kind == :file
      assert record.content == nil
      assert record.name == "doc.pdf"
      assert record.mime_type == "application/pdf"
      assert record.size == 1024
      assert record.url == "telegram://file/abc123"
      assert record.attributes["source"] == "channel_attachment"
    end

    test "creates stub records for multiple media items" do
      media = [
        %Media{
          kind: :file,
          url: "telegram://file/f1",
          filename: "a.pdf",
          media_type: "application/pdf"
        },
        %Media{kind: :file, url: "telegram://file/f2", filename: "b.png", media_type: "image/png"}
      ]

      records = TargetMedia.build_records(media, :telegram, %{})

      assert length(records) == 2
    end

    test "handles media with only url and kind" do
      media = [%Media{kind: :file, url: "telegram://file/xyz"}]

      [record] = TargetMedia.build_records(media, :telegram, %{})

      assert record.name == nil
      assert record.mime_type == nil
      assert record.size == nil
    end

    test "record_id uses url when no file_id in metadata" do
      media = [%Media{kind: :file, url: "some-url"}]

      [record] = TargetMedia.build_records(media, :telegram, %{})
      assert record.id == "telegram_some-url"
    end

    test "record_id uses metadata.file_id when present" do
      media = [
        %Media{
          kind: :file,
          url: "telegram://file/abc123",
          metadata: %{file_id: "custom_id"}
        }
      ]

      [record] = TargetMedia.build_records(media, :telegram, %{})
      assert record.id == "telegram_custom_id"
    end

    test "record_id uses url when metadata.file_id is nil" do
      media = [
        %Media{
          kind: :file,
          url: "fallback-url",
          metadata: %{file_id: nil}
        }
      ]

      [record] = TargetMedia.build_records(media, :telegram, %{})
      assert record.id == "telegram_fallback-url"
    end

    test "handles all media kinds" do
      media = [
        %Media{
          kind: :image,
          url: "telegram://file/img1",
          filename: "photo.jpg",
          media_type: "image/jpeg"
        },
        %Media{
          kind: :audio,
          url: "telegram://file/aud1",
          filename: "voice.ogg",
          media_type: "audio/ogg"
        },
        %Media{
          kind: :video,
          url: "telegram://file/vid1",
          filename: "clip.mp4",
          media_type: "video/mp4"
        },
        %Media{
          kind: :file,
          url: "telegram://file/doc1",
          filename: "notes.pdf",
          media_type: "application/pdf"
        }
      ]

      records = TargetMedia.build_records(media, :telegram, %{})

      assert length(records) == 4
      assert Enum.all?(records, &(&1.kind == :file))
    end

    test "provider is used in record_id prefix" do
      media = [%Media{kind: :file, url: "telegram://file/abc"}]

      tg_records = TargetMedia.build_records(media, :telegram, %{})
      mm_records = TargetMedia.build_records(media, :mattermost, %{})

      assert String.starts_with?(Enum.at(tg_records, 0).id, "telegram_")
      assert String.starts_with?(Enum.at(mm_records, 0).id, "mattermost_")
    end

    test "record has attributes.source = channel_attachment" do
      media = [%Media{kind: :file, url: "tg://doc"}]

      [record] = TargetMedia.build_records(media, :test, %{})
      assert record.attributes["source"] == "channel_attachment"
    end
  end
end
