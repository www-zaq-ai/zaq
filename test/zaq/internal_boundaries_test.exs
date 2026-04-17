defmodule Zaq.InternalBoundariesTest do
  use ExUnit.Case, async: true

  alias Zaq.{Event, InternalBoundaries}

  describe "invoke_request/1" do
    test "applies module function for valid request" do
      event = Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo)

      result = InternalBoundaries.invoke_request(event)

      assert result.response == "HELLO"
    end

    test "returns invalid_request error for malformed request" do
      event = Event.new(%{module: String, function: :upcase}, :bo)

      result = InternalBoundaries.invoke_request(event)

      assert result.response == {:error, {:invalid_request, %{module: String, function: :upcase}}}
    end
  end
end
