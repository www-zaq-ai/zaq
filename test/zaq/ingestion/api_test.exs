defmodule Zaq.Ingestion.ApiTest do
  use ExUnit.Case, async: true

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
end
