defmodule Zaq.Agent.CitationNormalizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  test "returns empty result for nil and non-binary input" do
    assert CitationNormalizer.normalize(nil, ["guide.md"]) == %{body: "", sources: []}
    assert CitationNormalizer.normalize(123, ["guide.md"]) == %{body: "", sources: []}
  end

  test "returns unchanged body when there are no markers" do
    result = CitationNormalizer.normalize("Plain answer without citations.", ["guide.md"])

    assert result == %{body: "Plain answer without citations.", sources: []}
  end

  test "handles empty body" do
    assert CitationNormalizer.normalize("", ["guide.md"]) == %{body: "", sources: []}
  end

  test "supports custom memory labels option" do
    answer = "This is known from prior analysis [[memory:team-playbook]]."
    result = CitationNormalizer.normalize(answer, ["guide.md"], memory_labels: ["team-playbook"])

    assert result.body == "This is known from prior analysis [1]."

    assert result.sources == [
             %{"index" => 1, "type" => "memory", "label" => "team-playbook"}
           ]
  end

  test "ignores malformed markers gracefully" do
    answer = "Bad [[source:]] and [[memory]] but valid [[source:guide.md]] marker."
    result = CitationNormalizer.normalize(answer, ["guide.md"])

    assert result.body == "Bad [[source:]] and [[memory]] but valid [1] marker."

    assert result.sources == [
             %{"index" => 1, "type" => "document", "path" => "guide.md"}
           ]
  end

  test "normalizes Unicode citation brackets with multibyte surrounding text" do
    path = "data_source/disk/2/a5862500-f085-427f-bbc0-dae9aa3e1c2a"
    answer = "Les visites d’août【source:#{path}】."

    assert CitationNormalizer.normalize(answer, [path]) == %{
             body: "Les visites d’août[1].",
             sources: [%{"index" => 1, "type" => "document", "path" => path}]
           }
  end

  test "shares numbering across bracket styles for documents and memory" do
    answer =
      "【source: docs/références.md 】 [[memory:llm-reasoning-inference]] " <>
        "[[source:docs/références.md]] 【memory:llm-reasoning-inference】"

    assert CitationNormalizer.normalize(answer, ["docs/références.md"]) == %{
             body: "[1] [2] [1] [2]",
             sources: [
               %{"index" => 1, "type" => "document", "path" => "docs/références.md"},
               %{"index" => 2, "type" => "memory", "label" => "llm-reasoning-inference"}
             ]
           }
  end

  test "validates Unicode markers against supplied sources and memory labels" do
    answer = "【source:missing.md】 【memory:unknown】 【memory:team-playbook】"

    assert CitationNormalizer.normalize(answer, [], memory_labels: ["team-playbook"]) == %{
             body: "[1]",
             sources: [%{"index" => 1, "type" => "memory", "label" => "team-playbook"}]
           }
  end

  test "leaves malformed and mismatched Unicode delimiters unchanged" do
    for answer <- ["【source:】", "【memory】", "【source:guide.md]]", "[[source:guide.md】"] do
      assert CitationNormalizer.normalize(answer, ["guide.md"]) == %{body: answer, sources: []}
    end
  end

  property "bracket styles preserve source validation and reference deduplication" do
    check all(name <- string(:alphanumeric, min_length: 1, max_length: 60)) do
      path = "docs/références/#{name}.md"
      answer = "【source:#{path}】 [[source:#{path}]] 【source:missing/#{name}.md】"

      assert CitationNormalizer.normalize(answer, [path]) == %{
               body: "[1] [1]",
               sources: [%{"index" => 1, "type" => "document", "path" => path}]
             }

      assert CitationNormalizer.normalize(answer, []) == %{body: "", sources: []}
    end
  end

  test "supports unicode marker values" do
    answer = "Voir les details [[source:docs/références.md]]."
    result = CitationNormalizer.normalize(answer, ["docs/références.md"])

    assert result.body == "Voir les details [1]."

    assert result.sources == [
             %{"index" => 1, "type" => "document", "path" => "docs/références.md"}
           ]
  end
end
