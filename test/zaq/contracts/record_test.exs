defmodule Zaq.Contracts.RecordTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Event

  describe "JSON encoding" do
    # D2: a dispatchable event inside a data payload is a confused-deputy risk. Keeping
    # `materializing_event` out of the encoder means it can never survive a round trip
    # through an LLM tool result or persisted workflow state, so a record rebuilt from
    # JSON can never carry an attacker-chosen event.
    test "omits materializing_event" do
      event =
        Event.new(%{provider: "disk", params: %{"file_id" => "42"}}, :channels,
          opts: [action: :data_source_download_document]
        )

      record = %Record{id: "42", kind: :file, content: "bytes", materializing_event: event}

      decoded = record |> Jason.encode!() |> Jason.decode!()

      refute Map.has_key?(decoded, "materializing_event")
      assert decoded["id"] == "42"
      assert decoded["content"] == "bytes"
    end

    test "omits the raw field" do
      record = %Record{id: "42", kind: :file, raw: %{"secret" => "provider internals"}}

      decoded = record |> Jason.encode!() |> Jason.decode!()

      refute Map.has_key?(decoded, "raw")
    end

    test "encodes an unmaterialized record with a null content" do
      record = %Record{id: "42", kind: :file, name: "pricing.pdf", content: nil}

      decoded = record |> Jason.encode!() |> Jason.decode!()

      assert decoded["content"] == nil
      assert decoded["name"] == "pricing.pdf"
    end
  end

  describe "struct" do
    test "defaults materializing_event to nil" do
      assert %Record{id: "1", kind: :file}.materializing_event == nil
    end

    test "still enforces id and kind" do
      assert_raise ArgumentError, fn -> struct!(Record, %{content: "x"}) end
    end
  end
end
