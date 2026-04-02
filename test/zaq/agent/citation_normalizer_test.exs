defmodule Zaq.Agent.CitationNormalizerTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.CitationNormalizer

  test "normalizes source and memory markers into numbered citations" do
    answer =
      "ZAQ is deployed on-prem. [[source:docs/deployment.md]] Also follows best practices [[memory:llm-general-knowledge]]."

    result = CitationNormalizer.normalize(answer, ["docs/deployment.md"])

    assert result.body == "ZAQ is deployed on-prem. [1] Also follows best practices [2]."

    assert result.sources == [
             %{"index" => 1, "type" => "document", "path" => "docs/deployment.md"},
             %{"index" => 2, "type" => "memory", "label" => "llm-general-knowledge"}
           ]
  end

  test "reuses numbers for repeated markers and drops unknown entries" do
    answer =
      "One [[source:guide.md]] Two [[source:guide.md]] Unknown [[source:missing.md]] " <>
        "Memory [[memory:unknown-memory]]."

    result = CitationNormalizer.normalize(answer, ["guide.md"])

    assert result.body == "One [1] Two [1] Unknown  Memory ."

    assert result.sources == [
             %{"index" => 1, "type" => "document", "path" => "guide.md"}
           ]
  end
end
