defmodule Zaq.Agent.TokenEstimatorTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.TokenEstimator

  describe "estimate/1" do
    test "estimates tokens for a simple sentence" do
      # 2 words × 1.3 = 2.6 → ceil = 3
      assert TokenEstimator.estimate("Hello world") == 3
    end

    test "returns 0 for empty string" do
      assert TokenEstimator.estimate("") == 0
    end

    test "returns 0 for non-binary input" do
      assert TokenEstimator.estimate(nil) == 0
    end

    test "handles multiple spaces between words" do
      # 3 words × 1.3 = 3.9 → ceil = 4
      assert TokenEstimator.estimate("one   two   three") == 4
    end

    test "handles newlines and tabs as whitespace" do
      # 4 words × 1.3 = 5.2 → ceil = 6
      assert TokenEstimator.estimate("one\ntwo\tthree four") == 6
    end

    test "single word" do
      # 1 word × 1.3 = 1.3 → ceil = 2
      assert TokenEstimator.estimate("hello") == 2
    end

    test "longer text produces proportional estimate" do
      short = TokenEstimator.estimate("a b c")
      long = TokenEstimator.estimate("a b c d e f g h i j")
      assert long > short
    end
  end
end
