defmodule Zaq.Engine.Conversations.MessageTraceArtifactTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Conversations.MessageTraceArtifact

  property "accepts content exactly when its size and digest match within the limit" do
    check all(content <- binary(min_length: 1, max_length: 1_024)) do
      attrs = %{
        tool_call_id: "tool-1",
        tool_name: "download_document",
        name: "attachment.bin",
        mime_type: "application/octet-stream",
        size: byte_size(content),
        sha256: :crypto.hash(:sha256, content),
        content: content,
        record: %{"id" => "media-1"}
      }

      changeset =
        MessageTraceArtifact.changeset(
          %MessageTraceArtifact{message_id: Ecto.UUID.generate()},
          attrs,
          1_024
        )

      assert changeset.valid?

      refute MessageTraceArtifact.changeset(
               %MessageTraceArtifact{message_id: Ecto.UUID.generate()},
               %{attrs | size: byte_size(content) + 1},
               1_024
             ).valid?

      refute MessageTraceArtifact.changeset(
               %MessageTraceArtifact{message_id: Ecto.UUID.generate()},
               %{attrs | sha256: <<0::256>>},
               1_024
             ).valid?
    end
  end

  property "rejects content larger than the configured limit" do
    check all(
            content <- binary(min_length: 2, max_length: 1_024),
            max_bytes <- integer(1..(byte_size(content) - 1))
          ) do
      attrs = %{
        tool_call_id: "tool-1",
        tool_name: "download_document",
        name: "attachment.bin",
        mime_type: "application/octet-stream",
        size: byte_size(content),
        sha256: :crypto.hash(:sha256, content),
        content: content
      }

      changeset =
        MessageTraceArtifact.changeset(
          %MessageTraceArtifact{message_id: Ecto.UUID.generate()},
          attrs,
          max_bytes
        )

      refute changeset.valid?
      assert {"exceeds the configured size limit", _opts} = changeset.errors[:content]
    end
  end
end
