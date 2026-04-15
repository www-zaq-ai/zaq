defmodule Zaq.Agent.LogprobsAnalyzerTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.LogprobsAnalyzer

  describe "logprob_to_prob/1" do
    test "converts logprob 0 to probability 1.0" do
      assert LogprobsAnalyzer.logprob_to_prob(0) == 1.0
    end

    test "converts negative logprob to probability between 0 and 1" do
      prob = LogprobsAnalyzer.logprob_to_prob(-1.0)
      assert prob > 0.0
      assert prob < 1.0
      assert_in_delta prob, 0.3679, 0.001
    end

    test "more negative logprob gives lower probability" do
      prob_low = LogprobsAnalyzer.logprob_to_prob(-5.0)
      prob_high = LogprobsAnalyzer.logprob_to_prob(-1.0)
      assert prob_low < prob_high
    end
  end

  describe "calculate_confidence/2" do
    test "calculates average confidence from logprobs content" do
      logprobs_content = [
        %{"logprob" => -0.1},
        %{"logprob" => -0.2},
        %{"logprob" => -0.3}
      ]

      assert {:ok, confidence} = LogprobsAnalyzer.calculate_confidence(logprobs_content)
      assert is_float(confidence)
      assert confidence > 0.0
      assert confidence < 1.0
    end

    test "returns rounded confidence when round is true" do
      logprobs_content = [
        %{"logprob" => -0.1},
        %{"logprob" => -0.2}
      ]

      assert {:ok, confidence} = LogprobsAnalyzer.calculate_confidence(logprobs_content, true)
      # Should be rounded to 2 decimal places
      assert confidence == Float.round(confidence, 2)
    end

    test "perfect logprobs return confidence of 1.0" do
      logprobs_content = [
        %{"logprob" => 0},
        %{"logprob" => 0}
      ]

      assert {:ok, confidence} = LogprobsAnalyzer.calculate_confidence(logprobs_content)
      assert confidence == 1.0
    end

    test "returns error for nil input" do
      assert {:error, :invalid_logprobs_content} = LogprobsAnalyzer.calculate_confidence(nil)
    end

    test "returns error for empty content" do
      assert {:error, :empty_logprobs_content} = LogprobsAnalyzer.calculate_confidence([])
    end

    test "returns error when no usable logprob entries exist" do
      assert {:error, :missing_logprobs_content} =
               LogprobsAnalyzer.calculate_confidence([%{"token" => "x"}, %{}])
    end

    test "accepts atom-keyed logprob entries" do
      logprobs_content = [
        %{token: "x", logprob: -0.2},
        %{token: "y", logprob: -0.4}
      ]

      assert {:ok, confidence} = LogprobsAnalyzer.calculate_confidence(logprobs_content)
      assert is_float(confidence)
      assert confidence > 0.0
      assert confidence < 1.0
    end
  end

  describe "confidence_from_metadata_or_nil/2" do
    test "reads string-keyed metadata produced by current LangChain" do
      metadata = %{
        "logprobs" => %{
          "content" => [
            %{"token" => "x", "logprob" => -0.2}
          ]
        }
      }

      assert {:ok, score} = LogprobsAnalyzer.confidence_from_metadata(metadata, true)
      assert is_float(score)
      assert score > 0.0
      assert score < 1.0
    end

    test "confidence_from_metadata returns tagged tuple directly" do
      metadata = %{
        "logprobs" => %{
          "content" => [
            %{"token" => "x", "logprob" => -0.2}
          ]
        }
      }

      assert {:ok, score} = LogprobsAnalyzer.confidence_from_metadata(metadata)
      assert is_float(score)
    end

    test "reads atom-keyed metadata for backward compatibility" do
      metadata = %{
        logprobs: %{
          content: [
            %{token: "x", logprob: -0.2}
          ]
        }
      }

      assert {:ok, score} = LogprobsAnalyzer.confidence_from_metadata(metadata, true)
      assert is_float(score)
      assert score > 0.0
      assert score < 1.0
    end

    test "returns nil when metadata is missing logprobs" do
      assert LogprobsAnalyzer.confidence_from_metadata_or_nil(%{}) == nil
      assert LogprobsAnalyzer.confidence_from_metadata_or_nil(nil) == nil
    end

    test "returns score from confidence_from_metadata_or_nil for valid metadata" do
      metadata = %{logprobs: %{content: [%{token: "x", logprob: -0.2}]}}
      assert is_float(LogprobsAnalyzer.confidence_from_metadata_or_nil(metadata, true))
    end

    test "reads logprobs content from list-shaped metadata value" do
      metadata = %{
        "logprobs" => [
          %{"token" => "x", "logprob" => -0.2},
          %{token: "y", logprob: -0.4}
        ]
      }

      assert {:ok, score} = LogprobsAnalyzer.confidence_from_metadata(metadata, true)
      assert is_float(score)
      assert score > 0.0
      assert score < 1.0
    end

    test "returns nil for invalid metadata shapes" do
      assert LogprobsAnalyzer.confidence_from_metadata_or_nil("not-a-map") == nil
      assert LogprobsAnalyzer.confidence_from_metadata_or_nil(%{logprobs: "invalid"}) == nil
    end
  end

  describe "token_confidences/1" do
    test "returns per-token confidence with alternatives" do
      logprobs_content = [
        %{
          "token" => "Hello",
          "logprob" => -0.1,
          "top_logprobs" => [
            %{"token" => "Hi", "logprob" => -0.5},
            %{"token" => "Hey", "logprob" => -1.0}
          ]
        }
      ]

      [result] = LogprobsAnalyzer.token_confidences(logprobs_content)

      assert result.token == "Hello"
      assert is_float(result.confidence)
      assert length(result.alternatives) == 2
      assert hd(result.alternatives).token == "Hi"
    end

    test "returns empty list for empty input" do
      assert LogprobsAnalyzer.token_confidences([]) == []
    end

    test "returns empty list for invalid input" do
      assert LogprobsAnalyzer.token_confidences(nil) == []
      assert LogprobsAnalyzer.token_confidences(%{}) == []
    end

    test "ignores invalid token entries inside list" do
      assert LogprobsAnalyzer.token_confidences([%{"token" => "x"}, %{foo: :bar}]) == []
    end

    test "supports atom-keyed token entries and alternatives" do
      logprobs_content = [
        %{
          token: "Hello",
          logprob: -0.3,
          top_logprobs: [
            %{token: "Hi", logprob: -0.8},
            %{"token" => "Hey", "logprob" => -1.1}
          ]
        }
      ]

      [result] = LogprobsAnalyzer.token_confidences(logprobs_content)
      assert result.token == "Hello"
      assert is_float(result.confidence)
      assert Enum.map(result.alternatives, & &1.token) == ["Hi", "Hey"]
    end

    test "ignores invalid top_logprobs shape" do
      logprobs_content = [
        %{"token" => "Hello", "logprob" => -0.3, "top_logprobs" => %{"bad" => true}}
      ]

      [result] = LogprobsAnalyzer.token_confidences(logprobs_content)
      assert result.alternatives == []
    end

    test "ignores invalid alternative entries in top_logprobs list" do
      logprobs_content = [
        %{"token" => "Hello", "logprob" => -0.3, "top_logprobs" => [%{"token" => "NoProb"}]}
      ]

      [result] = LogprobsAnalyzer.token_confidences(logprobs_content)
      assert result.alternatives == []
    end
  end
end
