defmodule Zaq.System.RAGModelConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.System.RAGModelConfig

  test "requires a complete selection, with blank configuration allowed" do
    assert RAGModelConfig.changeset(%RAGModelConfig{}, %{}).valid?
    refute RAGModelConfig.changeset(%RAGModelConfig{}, %{credential_id: 1}).valid?
    refute RAGModelConfig.changeset(%RAGModelConfig{}, %{model: "rerank"}).valid?
  end

  property "model names alone never grant specialized capabilities" do
    check all(name <- string(:alphanumeric)) do
      model = %{
        id: "rerank-#{name}",
        capabilities: %{rerank: false},
        modalities: %{output: [:text]}
      }

      refute RAGModelConfig.supports?(model, :reranking)
      refute RAGModelConfig.supports?(model, :decision)
      assert RAGModelConfig.supports?(%{model | capabilities: %{rerank: true}}, :reranking)
      assert RAGModelConfig.supports?(%{model | modalities: %{output: [:decisions]}}, :decision)
    end
  end
end
