defmodule Zaq.Contracts.RecordCapabilityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.{Record, RecordCapability}

  property "any changed source reference invalidates a signed capability" do
    check all(source_id <- string(:alphanumeric, min_length: 1, max_length: 64)) do
      record =
        %Record{
          id: source_id,
          kind: :file,
          name: "attachment.png",
          mime_type: "image/png",
          size: 4,
          attributes: %{
            "source_type" => "communication_media",
            "provider" => "mattermost",
            "source_id" => source_id,
            "channel_config_id" => "channel-1",
            "source_author_id" => "author-1"
          }
        }
        |> RecordCapability.sign!()

      assert :ok = RecordCapability.verify(record)

      assert :ok =
               RecordCapability.authorize(record, %{
                 actor: %{id: "author-1", person: %{id: 123}}
               })

      assert {:error, :unauthorized_record_capability} =
               RecordCapability.authorize(record, %{actor: %{id: "other-author"}})

      assert {:error, :unauthorized_record_capability} =
               RecordCapability.authorize(record, %{actor: %{person: %{id: 123}}})

      tampered = put_in(record.attributes["source_id"], source_id <> "-changed")
      refute :ok == RecordCapability.verify(tampered)
    end
  end

  test "binds projection metadata and rejects unsigned records" do
    record = %Record{
      id: "media-1",
      kind: :file,
      name: "attachment.png",
      mime_type: "image/png",
      size: 4,
      attributes: %{
        "source_type" => "communication_media",
        "provider" => "mattermost",
        "source_id" => "media-1",
        "source_author_id" => "author-1"
      }
    }

    assert {:error, :invalid_record_capability} = RecordCapability.verify(record)

    signed = RecordCapability.sign!(record)

    for tampered <- [
          %{signed | name: "other.png"},
          %{signed | mime_type: "text/html"},
          %{signed | size: 3},
          %{signed | id: "other-media"}
        ] do
      assert {:error, :invalid_record_capability} = RecordCapability.verify(tampered)
    end
  end
end
