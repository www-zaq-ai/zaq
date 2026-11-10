defmodule Zaq.Agent.Tools.KnowledgeSourcesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.KnowledgeSources

  test "source identities are returned regardless of content accessibility" do
    assert KnowledgeSources.from_chunks([
             %{"source" => "public.md", "content" => "text"},
             %{"source" => "private.md", "content" => "You don't have access to this chunk."},
             %{"source" => "public.md"},
             %{"source" => ""},
             %{}
           ]) == ["public.md", "private.md"]
  end

  property "sources preserve first occurrence order without duplicates" do
    check all(paths <- list_of(string(:alphanumeric, min_length: 1, max_length: 30))) do
      assert KnowledgeSources.from_chunks(Enum.map(paths, &%{"source" => &1})) == Enum.uniq(paths)
    end
  end
end
