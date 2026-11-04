defmodule Zaq.Agent.Tools.KnowledgeRetrievalGuidanceTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.{GetKnowledgeBaseChunks, SearchKnowledgeBase}

  test "search advertises usable content and purposeful retrieval" do
    description = SearchKnowledgeBase.description()

    assert description =~ "usable content"
    assert description =~ "near-identical parallel searches"
    assert description =~ "distinct information need"
    assert description =~ "Stop retrieving"
    assert description =~ "previous_chunk_id/next_chunk_id"
  end

  test "exact fetch advertises safe navigation without redundant content" do
    description = GetKnowledgeBaseChunks.description()

    assert description =~ "already visible"
    assert description =~ "refresh"
    assert description =~ "pruned"
    assert description =~ "Never guess"
    assert description =~ "contiguous"
    assert description =~ "returned neighbor IDs"
    assert description =~ "permissions"
  end
end
