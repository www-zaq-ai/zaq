defmodule Zaq.System.OperationModelConfigTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.ProviderSpec
  alias Zaq.Engine.Conversations.TitleGenerator
  alias Zaq.System
  alias Zaq.System.OperationModelConfig
  import Zaq.SystemConfigFixtures

  test "Small model initialization ignores translation and unrelated global settings" do
    assert {:ok, _} = System.set_config("rag.translation.model", "openai/gpt-oss-20b")
    assert {:ok, _} = System.set_config("global.small_model.unrelated", "saved")

    refute System.model_config_initialized?(:small)
  end

  test "an explicitly cleared Small model selection is initialized" do
    refute System.model_config_initialized?(:small)

    assert {:ok, _} =
             System.save_operation_model_config(:small, %{credential_id: nil, model: nil})

    assert System.model_config_initialized?(:small)
  end

  property "any saved Small model field marks initialization regardless of its value" do
    check all(
            field <- member_of(~w(credential_id model temperature top_p)),
            value <- one_of([constant(nil), constant(""), string(:printable, max_length: 30)])
          ) do
      refute System.model_config_initialized?(:small)
      key = "global.small_model.#{field}"
      assert {:ok, _} = System.set_config(key, value)
      assert System.model_config_initialized?(:small)

      Repo.delete_all(from(config in Zaq.System.Config, where: config.key == ^key))
    end
  end

  test "initialization distinguishes absent settings from partial or explicitly cleared choices" do
    for kind <- [:translation, :reranking, :decision] do
      refute System.model_config_initialized?(kind)
    end

    assert {:ok, _} = System.set_config("rag.translation.temperature", "0.4")
    assert System.model_config_initialized?(:translation)

    for kind <- [:reranking, :decision] do
      assert {:ok, _} = System.save_rag_model_config(kind, %{credential_id: nil, model: nil})
      assert System.model_config_initialized?(kind)
    end
  end

  test "atomic pairs persist independently and protect referenced credentials" do
    credential = ai_credential_fixture(%{provider: "openai"})

    assert {:ok, translation} =
             System.save_operation_model_config(:translation, %{
               credential_id: credential.id,
               model: "gpt-4o",
               temperature: 0.3
             })

    assert translation.temperature == 0.3
    assert System.get_operation_model_config(:small).credential_id == nil
    assert {:error, _} = System.delete_ai_provider_credential(credential)

    assert {:error, _} =
             System.save_operation_model_config(:translation, %{model: "missing-catalog-model"})

    assert System.get_operation_model_config(:translation) == translation

    assert {:ok, cleared} =
             System.save_operation_model_config(:translation, %{credential_id: "", model: ""})

    assert cleared.credential_id == nil
    assert cleared.model == nil
  end

  test "unconfigured operations do not inherit an otherwise usable global model" do
    credential = ai_credential_fixture()
    System.set_config("llm.credential_id", credential.id)
    System.set_config("llm.model", "gpt-4o")

    assert {:error, :model_not_configured} =
             ProviderSpec.operation_runtime(System.get_operation_model_config(:translation))

    assert {:fallback, "Reset My Password", :model_not_configured} =
             TitleGenerator.generate("reset my password")
  end

  test "catalog filtering excludes non-text outputs" do
    assert OperationModelConfig.supports?(%{modalities: %{output: [:text]}})
    refute OperationModelConfig.supports?(%{modalities: %{output: [:decisions]}})
    refute OperationModelConfig.supports?(%{modalities: nil})
  end

  test "decision and reranking reuse pair validation without accepting generation sampling" do
    for kind <- [:decision, :reranking] do
      assert OperationModelConfig.changeset(%OperationModelConfig{}, %{}, kind).valid?

      refute OperationModelConfig.changeset(%OperationModelConfig{}, %{credential_id: 1}, kind).valid?

      refute OperationModelConfig.changeset(%OperationModelConfig{}, %{model: "model"}, kind).valid?

      refute OperationModelConfig.changeset(
               %OperationModelConfig{},
               %{credential_id: -1, model: "model"},
               kind
             ).valid?

      changeset =
        OperationModelConfig.changeset(
          %OperationModelConfig{},
          %{credential_id: 1, model: "model", temperature: "invalid", top_p: -1},
          kind
        )

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :temperature)
      refute Map.has_key?(changeset.changes, :top_p)
    end

    refute OperationModelConfig.changeset(%OperationModelConfig{}, %{temperature: "invalid"}).valid?

    refute OperationModelConfig.changeset(%OperationModelConfig{}, %{top_p: -1}).valid?
    assert OperationModelConfig.supports?(%{capabilities: %{rerank: true}}, :reranking)
    assert OperationModelConfig.supports?(%{modalities: %{output: [:decisions]}}, :decision)
    refute OperationModelConfig.supports?(%{modalities: %{output: [:text]}}, :decision)
  end

  test "non-generation model selections never persist sampling fields" do
    credential = ai_credential_fixture(%{provider: "custom"})

    for {kind, namespace} <- [decision: "global.decision_model", reranking: "rag.reranking"] do
      attrs = %{credential_id: credential.id, model: "custom-model", temperature: 1.8, top_p: 0.1}
      assert {:ok, %OperationModelConfig{}} = System.save_rag_model_config(kind, attrs)
      assert System.get_config("#{namespace}.model") == "custom-model"
      assert System.get_config("#{namespace}.temperature") == nil
      assert System.get_config("#{namespace}.top_p") == nil
    end
  end
end
