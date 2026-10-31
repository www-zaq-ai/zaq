defmodule Zaq.System.RAGSettingsTest do
  use Zaq.DataCase, async: true

  alias Zaq.System
  alias Zaq.System.LLMConfig
  alias Zaq.System.RAGModelConfig

  test "specialized selections start unset and persist independently" do
    assert %RAGModelConfig{credential_id: nil, model: nil} =
             System.get_rag_model_config(:reranking)

    credential = Zaq.SystemConfigFixtures.ai_credential_fixture()
    attrs = %{"credential_id" => to_string(credential.id), "model" => "rerank-test"}
    assert {:ok, config} = System.save_rag_model_config(:reranking, attrs)
    assert config.credential_id == credential.id
    assert config.model == "rerank-test"
    assert System.get_rag_model_config(:reranking) == config
    assert System.get_rag_model_config(:decision).model == nil
    assert {:error, _} = System.save_rag_model_config(:decision, %{"model" => "decision-test"})
    assert {:error, _} = System.delete_ai_provider_credential(credential)

    assert {:ok, %RAGModelConfig{credential_id: nil, model: nil}} =
             System.save_rag_model_config(:reranking, %{"credential_id" => "", "model" => ""})
  end

  test "retrieval writes do not require an LLM credential or overwrite other settings" do
    System.set_config("llm.model", "keep-chat-model")
    assert {:ok, config} = System.save_retrieval_config(%{"max_cosine_distance" => "0.7"})
    assert config.max_cosine_distance == 0.7
    assert System.get_config("llm.model") == "keep-chat-model"

    assert {:error, _} =
             System.save_retrieval_config(%{
               "fusion_bm25_weight" => "0",
               "fusion_vector_weight" => "0"
             })

    assert System.get_llm_config().fusion_bm25_weight == 0.5
    assert {:error, _} = System.save_retrieval_config(%{"max_cosine_distance" => ""})
  end

  test "retrieval-only changesets ignore chat and credential fields" do
    cs =
      LLMConfig.retrieval_changeset(%LLMConfig{}, %{
        "model" => "overwrite",
        "max_cosine_distance" => "2"
      })

    assert cs.valid?
    refute Map.has_key?(cs.changes, :model)
  end
end
