defmodule Zaq.Contracts.RecordMaterializerTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordMaterializer
  alias Zaq.Event

  defmodule OkNodeRouter do
    def dispatch(%Event{request: %{id: "bytes"}} = event) do
      send(self(), {:dispatch, event})
      %{event | response: {:ok, %{content: "hello"}}}
    end
  end

  defmodule AtomEncodingNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %{content: "aGVsbG8=", encoding: "base64"}}}
    end
  end

  defmodule StringEncodingNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %{"encoding" => "base64", content: "aGVsbG8="}}}
    end
  end

  defmodule RecordResponseNodeRouter do
    def dispatch(%Event{} = event) do
      response_record = %Record{
        id: "downloaded",
        kind: :file,
        content: "downloaded content",
        attributes: %{"encoding" => "base64"}
      }

      %{event | response: {:ok, %{record: response_record}}}
    end
  end

  defmodule PlainMapRecordResponseNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %{record: %{content: "plain map content", encoding: "base64"}}}}
    end
  end

  defmodule RecordWithoutEncodingAttrsNodeRouter do
    def dispatch(%Event{} = event) do
      response_record = %Record{
        id: "downloaded",
        kind: :file,
        content: "downloaded without encoding",
        attributes: nil
      }

      %{event | response: {:ok, %{record: response_record}}}
    end
  end

  defmodule NonMapAttributesNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %{content: "hello", attributes: "not-a-map"}}}
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :timeout}}
  end

  defmodule BinaryErrorNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, "download failed"}}
  end

  defmodule UnexpectedOkNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:ok, %{bytes: "hello"}}}
  end

  defmodule UnexpectedResponseNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: :weird_response}
  end

  test "passes through records that already have content" do
    payload = %{record: %Record{id: "r1", kind: :file, content: "ready"}}

    assert RecordMaterializer.materialize(payload, %{}, "failed") == {:ok, payload}
  end

  test "passes through records with no materializing event" do
    payload = %{record: %Record{id: "r1", kind: :file, content: nil}}

    assert RecordMaterializer.materialize(payload, %{}, "failed") == {:ok, payload}
  end

  test "dispatches materializing event and merges returned content" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:ok, %{record: %Record{content: "hello"}}} =
             RecordMaterializer.materialize(payload, %{node_router: OkNodeRouter}, "failed")

    assert_received {:dispatch, ^event}
  end

  test "copies atom encoding onto record attributes" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: AtomEncodingNodeRouter},
               "failed"
             )

    assert record.content == "aGVsbG8="
    assert record.attributes["encoding"] == "base64"
  end

  test "copies string encoding onto record attributes" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: StringEncodingNodeRouter},
               "failed"
             )

    assert record.content == "aGVsbG8="
    assert record.attributes["encoding"] == "base64"
  end

  test "merges content from current download_document record responses" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :data_source_download_document])

    payload = %{
      record: %Record{
        id: "metadata",
        kind: :file,
        name: "Metadata Name",
        materializing_event: event
      }
    }

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: RecordResponseNodeRouter},
               "failed"
             )

    assert record.id == "metadata"
    assert record.name == "Metadata Name"
    assert record.content == "downloaded content"
    assert record.attributes["encoding"] == "base64"
  end

  test "merges content from plain map record responses" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])

    payload = %{
      record: %Record{
        id: "original",
        kind: :file,
        name: "Original Name",
        materializing_event: event
      }
    }

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: PlainMapRecordResponseNodeRouter},
               "failed"
             )

    assert record.id == "original"
    assert record.name == "Original Name"
    assert record.content == "plain map content"
    assert record.attributes["encoding"] == "base64"
  end

  test "preserves attributes when record responses have no encoding attributes" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])

    payload = %{
      record: %Record{
        id: "r1",
        kind: :file,
        attributes: %{"source" => "original"},
        materializing_event: event
      }
    }

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: RecordWithoutEncodingAttrsNodeRouter},
               "failed"
             )

    assert record.content == "downloaded without encoding"
    assert record.attributes == %{"source" => "original"}
    refute Map.has_key?(record.attributes, "encoding")
  end

  test "does not read encoding from non-map attributes" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])

    payload = %{
      record: %Record{
        id: "r1",
        kind: :file,
        attributes: %{"source" => "original"},
        materializing_event: event
      }
    }

    assert {:ok, %{record: record}} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: NonMapAttributesNodeRouter},
               "failed"
             )

    assert record.content == "hello"
    assert record.attributes == %{"source" => "original"}
    refute Map.has_key?(record.attributes, "encoding")
  end

  test "formats materializing errors" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:error, "failed: :timeout"} =
             RecordMaterializer.materialize(payload, %{node_router: ErrorNodeRouter}, "failed")
  end

  test "returns binary materializing error reasons without inspection" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:error, "failed: download failed"} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: BinaryErrorNodeRouter},
               "failed"
             )
  end

  test "formats unexpected ok payloads" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:error, "failed: unexpected materialize response %{bytes: \"hello\"}"} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: UnexpectedOkNodeRouter},
               "failed"
             )
  end

  test "formats unexpected materializing responses" do
    event = Event.new(%{id: "bytes"}, :channels, opts: [action: :download_bytes])
    payload = %{record: %Record{id: "r1", kind: :file, materializing_event: event}}

    assert {:error, "Unexpected materialize response: :weird_response"} =
             RecordMaterializer.materialize(
               payload,
               %{node_router: UnexpectedResponseNodeRouter},
               "failed"
             )
  end
end
