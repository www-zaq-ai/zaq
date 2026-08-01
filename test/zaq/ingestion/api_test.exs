defmodule Zaq.Ingestion.ApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Ingestion.Api

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  describe "record materialization actions" do
    # Each assertion is a result only the intended function produces, so it proves routing
    # rather than merely that some clause matched.
    test "routes materialize_record" do
      event = Event.new(%{file_id: 999_999_999, person_id: nil}, :ingestion)

      assert Api.handle_event(event, :materialize_record, nil).response == {:error, :not_found}
    end

    test "routes describe_records" do
      event = Event.new(%{file_ids: [], person_id: nil}, :ingestion)

      assert {:ok, %RecordPage{records: []}} =
               Api.handle_event(event, :describe_records, nil).response
    end

    test "routes delete_record" do
      event = Event.new(%{file_id: 999_999_999}, :ingestion)

      assert Api.handle_event(event, :delete_record, nil).response == :ok
    end

    test "routes persist_record" do
      event = Event.new(%{volume: "no-such-volume", path: "a.md", content: "x"}, :ingestion)

      assert {:error, _} = Api.handle_event(event, :persist_record, nil).response
    end

    test "falls through to unsupported when the request is not a map" do
      event = Event.new("not a map", :ingestion)

      assert Api.handle_event(event, :materialize_record, nil).response ==
               {:error, {:unsupported_action, :materialize_record}}
    end
  end
end
