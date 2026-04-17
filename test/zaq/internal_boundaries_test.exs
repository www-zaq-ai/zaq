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

  describe "default_handle_event/2" do
    test "delegates invoke action to invoke_request" do
      event = Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo)

      result = InternalBoundaries.default_handle_event(event, :invoke)

      assert result.response == "HELLO"
    end

    test "returns unsupported_action for non-invoke action" do
      event = Event.new(%{module: String, function: :upcase, args: ["hello"]}, :bo)

      result = InternalBoundaries.default_handle_event(event, :unknown)

      assert result.response == {:error, {:unsupported_action, :unknown}}
    end
  end
end
