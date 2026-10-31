defmodule Zaq.System.OperationModelConfigTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.ProviderSpec
  alias Zaq.Engine.Conversations.TitleGenerator
  alias Zaq.System
  alias Zaq.System.OperationModelConfig
  import Zaq.SystemConfigFixtures

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
    seed_llm_config(%{model: "gpt-4o"})

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
end
