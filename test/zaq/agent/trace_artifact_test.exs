defmodule Zaq.Agent.TraceArtifactTest do
  # A stub router stands in for the engine hop so these cover the rewrite of the tool result
  # itself. The stored row is covered by `Zaq.Engine.Conversations.MessageTraceArtifactTest`.
  use ExUnit.Case, async: true

  alias Zaq.Agent.TraceArtifact
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Event

  defmodule StubRouter do
    @moduledoc false

    def dispatch(%Event{} = event) do
      send(self(), {:stored, event.request})

      %{
        event
        | response:
            Process.get(
              :store_response,
              {:ok, %MessageTraceArtifact{id: "11111111-0000-0000-0000-000000000000"}}
            )
      }
    end
  end

  defp state, do: %{node_router: StubRouter}

  defp result(record_attrs \\ %{}) do
    record =
      struct!(
        %Record{
          id: "telegram://file/abc",
          kind: :file,
          name: "photo.png",
          mime_type: "image/png",
          content: Base.encode64("PNGBYTES"),
          attributes: %{"encoding" => "base64"}
        },
        record_attrs
      )

    %{record: record}
  end

  describe "storing what a tool read" do
    test "the bytes leave the result and an id takes their place" do
      assert %{record: record} = TraceArtifact.store(result(), "call_1", state())

      assert record.content == nil
      assert record.attributes["trace_artifact_id"] == "11111111-0000-0000-0000-000000000000"
    end

    test "stores decoded bytes, not the base64 they travelled as" do
      TraceArtifact.store(result(), "call_1", state())

      assert_received {:stored, %{content: "PNGBYTES"}}
    end

    test "size is the decoded length, not the encoded one" do
      TraceArtifact.store(result(), "call_1", state())

      assert_received {:stored, %{size: 8}}
      assert byte_size(Base.encode64("PNGBYTES")) == 12
    end

    test "raw content with no encoding attribute is stored as-is" do
      raw = result(%{content: "RAWBYTES", attributes: %{}})

      TraceArtifact.store(raw, "call_1", state())

      assert_received {:stored, %{content: "RAWBYTES", size: 8}}
    end

    test "name and type travel so a chip can be drawn without reading bytes" do
      TraceArtifact.store(result(), "call_1", state())

      assert_received {:stored, %{name: "photo.png", mime_type: "image/png"}}
    end

    test "the tool call it came from is what ties the row to the trace entry" do
      TraceArtifact.store(result(), "call_7", state())

      assert_received {:stored, %{tool_call_id: "call_7"}}
    end

    test "a size the provider already set is kept over the decoded one" do
      assert %{record: record} = TraceArtifact.store(result(%{size: 99}), "call_1", state())

      assert record.size == 99
    end

    test "a record with no size gets the decoded length, so a chip can show it" do
      assert %{record: record} = TraceArtifact.store(result(), "call_1", state())

      assert record.size == 8
    end
  end

  describe "the size cap" do
    test "an oversized read is recorded as metadata with no bytes" do
      oversized = :binary.copy("x", MessageTraceArtifact.max_content_bytes() + 1)

      TraceArtifact.store(result(%{content: oversized, attributes: %{}}), "call_1", state())

      assert_received {:stored, %{content: nil, size: size}}
      assert size == MessageTraceArtifact.max_content_bytes() + 1
    end

    test "content under the cap is stored whole" do
      under_cap = :binary.copy("x", 64_000)

      TraceArtifact.store(result(%{content: under_cap, attributes: %{}}), "call_1", state())

      assert_received {:stored, %{content: stored}}
      assert byte_size(stored) == 64_000
    end
  end

  describe "results that carry nothing to store" do
    test "a listing passes through untouched" do
      listing = %{attachments: [%{attachment_id: "a"}]}

      assert TraceArtifact.store(listing, "call_1", state()) == listing
      refute_received {:stored, _attrs}
    end

    test "a refusal passes through untouched" do
      refusal = %{refused: "cannot read image"}

      assert TraceArtifact.store(refusal, "call_1", state()) == refusal
      refute_received {:stored, _attrs}
    end

    test "a record with no content stores nothing" do
      empty = result(%{content: nil})

      assert TraceArtifact.store(empty, "call_1", state()) == empty
      refute_received {:stored, _attrs}
    end

    test "content that claims base64 but is not decodable stores nothing" do
      undecodable = result(%{content: "!!!not base64!!!"})

      assert TraceArtifact.store(undecodable, "call_1", state()) == undecodable
      refute_received {:stored, _attrs}
    end

    test "a tool call with no id stores nothing — there is nothing to tie a row to" do
      assert TraceArtifact.store(result(), nil, state()) == result()
      refute_received {:stored, _attrs}
    end

    test "a plain value that is not a tool payload passes through" do
      assert TraceArtifact.store("done", "call_1", state()) == "done"
    end
  end

  describe "a store that fails" do
    test "does not cost the turn — the result still travels, without bytes" do
      Process.put(:store_response, {:error, :boom})

      assert %{record: record} = TraceArtifact.store(result(), "call_1", state())

      assert record.content == nil
      refute Map.has_key?(record.attributes, "trace_artifact_id")
    end

    test "a raising router is caught rather than crashing the stream handler" do
      defmodule RaisingRouter do
        @moduledoc false
        def dispatch(_event), do: raise("engine unreachable")
      end

      assert %{record: record} =
               TraceArtifact.store(result(), "call_1", %{node_router: RaisingRouter})

      assert record.content == nil
    end
  end
end
