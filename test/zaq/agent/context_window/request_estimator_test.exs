defmodule Zaq.Agent.ContextWindow.RequestEstimatorTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ContextWindow.RequestEstimator

  describe "estimate/2" do
    test "counts the complete request shape, not only message content" do
      base = %{
        messages: [%{role: "user", content: "hello"}],
        llm_opts: [],
        tools: [],
        model: {:openai, model: "gpt-4.1-mini"}
      }

      with_tool = %{
        base
        | tools: [
            %{
              name: "large_tool",
              description: String.duplicate("tool schema ", 20),
              parameters: %{type: "object", properties: %{query: %{type: "string"}}}
            }
          ]
      }

      assert RequestEstimator.estimate(with_tool, tokens_per_character: 0.5) >
               RequestEstimator.estimate(base, tokens_per_character: 0.5)
    end

    test "uses the configured fixed token-per-character coefficient" do
      request = %{messages: [%{role: "user", content: String.duplicate("a", 100)}]}

      assert RequestEstimator.estimate(request, tokens_per_character: 0.6) >
               RequestEstimator.estimate(request, tokens_per_character: 0.2)
    end

    test "falls back to the default coefficient for unsupported calibration values" do
      request = %{messages: [%{role: "user", content: "hello"}]}
      expected = ceil(RequestEstimator.character_count(request) * 0.5)

      assert RequestEstimator.estimate(request, nil) == expected
    end
  end

  describe "character_count/1" do
    test "normalizes structs as their underlying maps" do
      date = ~D[2026-08-31]
      struct_request = %{output: date}
      map_request = %{output: Map.from_struct(date)}

      assert RequestEstimator.character_count(struct_request) ==
               RequestEstimator.character_count(map_request)
    end
  end
end
