defmodule Zaq.TestSupport.LiveRAGBenchTest do
  @moduledoc """
  Unit tests for the deterministic LiveRAG scoring helpers. Runs in normal CI
  (no `:benchmark_liverag` tag, no real credentials) — the LLM judge + pipeline
  run are exercised only by the tagged end-to-end benchmark.
  """
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.LiveRAGBench

  describe "source_to_doc_id/1 and doc_source/1 round-trip" do
    test "maps a liverag source back to its doc_id" do
      assert LiveRAGBench.source_to_doc_id("liverag:abc-123") == "abc-123"
    end

    test "returns nil for non-liverag sources" do
      assert LiveRAGBench.source_to_doc_id("other:abc") == nil
      assert LiveRAGBench.source_to_doc_id("") == nil
    end

    test "doc_source/1 is the inverse of source_to_doc_id/1" do
      id = "doc-42"
      assert id |> LiveRAGBench.doc_source() |> LiveRAGBench.source_to_doc_id() == id
    end
  end

  describe "recall/2" do
    test "full recall when all supporting docs retrieved" do
      assert LiveRAGBench.recall(["a", "b", "c"], ["a", "b"]) == 1.0
    end

    test "partial recall" do
      assert LiveRAGBench.recall(["a", "x"], ["a", "b"]) == 0.5
    end

    test "zero recall when none retrieved" do
      assert LiveRAGBench.recall(["x", "y"], ["a", "b"]) == 0.0
    end

    test "ignores duplicate retrieved ids" do
      assert LiveRAGBench.recall(["a", "a", "a"], ["a", "b"]) == 0.5
    end

    test "nil (excluded from mean) when there are no supporting docs" do
      assert LiveRAGBench.recall(["a"], []) == nil
    end
  end
end
