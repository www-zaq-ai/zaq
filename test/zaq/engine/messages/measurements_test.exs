defmodule Zaq.Engine.Messages.MeasurementsTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.Measurements

  describe "metadata_measurements/1" do
    test "drops atom and string token keys" do
      measurements = %{
        :input_tokens => 1,
        :output_tokens => 2,
        :prompt_tokens => 3,
        :completion_tokens => 4,
        :total_tokens => 5,
        "input_tokens" => 6,
        "output_tokens" => 7,
        "prompt_tokens" => 8,
        "completion_tokens" => 9,
        "total_tokens" => 10,
        "latency_ms" => 42,
        "tool_call_count" => 1
      }

      assert Measurements.metadata_measurements(measurements) == %{
               "latency_ms" => 42,
               "tool_call_count" => 1
             }
    end

    test "returns empty map for invalid input" do
      assert Measurements.metadata_measurements(nil) == %{}
      assert Measurements.metadata_measurements("bad") == %{}
    end
  end

  describe "token_measurements_from_message/1" do
    test "reads atom-key message token fields" do
      assert Measurements.token_measurements_from_message(%{
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15
             }) == %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }
    end

    test "reads string-key message token fields" do
      assert Measurements.token_measurements_from_message(%{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }) == %{
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }
    end

    test "fills missing values with not provided" do
      assert Measurements.token_measurements_from_message(%{completion_tokens: 5}) == %{
               "prompt_tokens" => "not provided",
               "completion_tokens" => 5,
               "total_tokens" => "not provided"
             }
    end

    test "returns not provided token rows for invalid input" do
      assert Measurements.token_measurements_from_message(nil) == %{
               "prompt_tokens" => "not provided",
               "completion_tokens" => "not provided",
               "total_tokens" => "not provided"
             }
    end
  end

  describe "message_info_measurements/1" do
    test "combines top-level runtime measurements and runtime token fields" do
      assert Measurements.message_info_measurements(%{
               measurements: %{
                 "latency_ms" => 42,
                 "input_tokens" => 999,
                 "total_tokens" => 999
               },
               prompt_tokens: 10,
               completion_tokens: 5,
               total_tokens: 15
             }) == %{
               "latency_ms" => 42,
               "prompt_tokens" => 10,
               "completion_tokens" => 5,
               "total_tokens" => 15
             }
    end

    test "combines persisted metadata measurements and message token fields" do
      assert Measurements.message_info_measurements(%{
               "metadata" => %{
                 "measurements" => %{
                   "latency_ms" => 42,
                   "output_tokens" => 999
                 }
               },
               "prompt_tokens" => 10,
               "completion_tokens" => nil,
               "total_tokens" => 15
             }) == %{
               "latency_ms" => 42,
               "prompt_tokens" => 10,
               "completion_tokens" => "not provided",
               "total_tokens" => 15
             }
    end

    test "returns not provided token rows when no token source is present" do
      assert Measurements.message_info_measurements(%{measurements: %{"latency_ms" => 42}}) == %{
               "latency_ms" => 42,
               "prompt_tokens" => "not provided",
               "completion_tokens" => "not provided",
               "total_tokens" => "not provided"
             }
    end

    test "returns empty map for invalid input" do
      assert Measurements.message_info_measurements(nil) == %{}
      assert Measurements.message_info_measurements("bad") == %{}
      assert Measurements.message_info_measurements([:not, :a, :message]) == %{}
    end
  end
end
