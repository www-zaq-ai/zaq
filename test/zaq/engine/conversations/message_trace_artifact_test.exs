defmodule Zaq.Engine.Conversations.MessageTraceArtifactTest do
  # The cap is a changeset rule, not a table constraint, so it is covered here as validation
  # rather than as a database refusal.
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.MessageTraceArtifact

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{
        tool_call_id: "call_1",
        name: "photo.png",
        mime_type: "image/png",
        size: 8,
        content: "PNGBYTES"
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "stores raw bytes, not a base64 string" do
      assert {:ok, artifact} = Conversations.create_trace_artifact(attrs())

      assert artifact.content == "PNGBYTES"
      assert artifact.size == 8
    end

    test "requires the tool call it came from" do
      assert {:error, changeset} =
               Conversations.create_trace_artifact(attrs(%{tool_call_id: nil}))

      assert "can't be blank" in errors_on(changeset).tool_call_id
    end

    test "refuses content over the cap rather than letting the driver raise" do
      oversized = :binary.copy("x", MessageTraceArtifact.max_content_bytes() + 1)

      assert {:error, changeset} =
               Conversations.create_trace_artifact(attrs(%{content: oversized}))

      assert changeset.errors[:content]
    end

    # Deliberately not inserting a cap-sized binary: it would push 100 MB through Postgrex on
    # every run to prove a boundary the rejection test already pins.
    test "content under the cap is kept" do
      under_cap = :binary.copy("x", 64_000)

      assert {:ok, artifact} = Conversations.create_trace_artifact(attrs(%{content: under_cap}))

      assert byte_size(artifact.content) == 64_000
    end

    test "metadata with no bytes is legal — that is how an oversized read is recorded" do
      assert {:ok, artifact} =
               Conversations.create_trace_artifact(
                 attrs(%{content: nil, size: 40_000_000, name: "big.pdf"})
               )

      assert artifact.content == nil
      assert artifact.size == 40_000_000
    end

    test "a negative size is refused" do
      assert {:error, changeset} = Conversations.create_trace_artifact(attrs(%{size: -1}))

      assert changeset.errors[:size]
    end
  end

  describe "get_trace_artifact/1" do
    test "reads back the bytes that were stored" do
      {:ok, stored} = Conversations.create_trace_artifact(attrs())

      assert %MessageTraceArtifact{content: "PNGBYTES"} =
               Conversations.get_trace_artifact(stored.id)
    end

    test "an id that names nothing is nil, not a crash" do
      assert Conversations.get_trace_artifact(Ecto.UUID.generate()) == nil
    end

    test "a malformed id is nil rather than an Ecto cast error" do
      assert Conversations.get_trace_artifact("not-a-uuid") == nil
    end

    test "a non-binary id is nil" do
      assert Conversations.get_trace_artifact(nil) == nil
    end
  end
end
