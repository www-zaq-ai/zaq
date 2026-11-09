defmodule Zaq.System.DecisionModelConfigTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.{Api, Events}
  alias Zaq.System
  import Zaq.SystemConfigFixtures

  test "global pair is authoritative and legacy accessors delegate without dual writes" do
    credential = ai_credential_fixture(%{provider: "custom"})
    System.set_config("rag.decision.credential_id", credential.id)
    System.set_config("rag.decision.model", "legacy")
    refute System.model_config_initialized?(:decision)
    assert %{credential_id: nil, model: nil} = System.get_decision_model_config()

    assert {:ok, selected} =
             System.save_decision_model_config(%{credential_id: credential.id, model: "decision"})

    assert System.get_rag_model_config(:decision) == selected
    assert System.get_config("global.decision_model.model") == "decision"
    assert System.get_config("rag.decision.model") == "legacy"
    assert System.model_config_initialized?(:decision)
    assert {:error, _} = System.delete_ai_provider_credential(credential)

    assert {:ok, %{credential_id: nil, model: nil}} =
             System.save_rag_model_config(:decision, %{credential_id: nil, model: nil})

    assert System.model_config_initialized?(:decision)
    assert {:ok, _} = System.delete_ai_provider_credential(credential)
  end

  test "partial saves reject changes without altering the global pair" do
    assert {:error, %Ecto.Changeset{}} = System.save_decision_model_config(%{model: "partial"})
    assert %{credential_id: nil, model: nil} = System.get_decision_model_config()
    refute System.model_config_initialized?(:decision)
  end

  test "Engine exposes the dedicated decision configuration boundary" do
    credential = ai_credential_fixture(%{provider: "custom"})
    attrs = %{credential_id: credential.id, model: "decision"}
    event = Events.build_invoke_event(%{attrs: attrs}, :system_config_save_decision_model_config)

    assert %{response: {:ok, config}} =
             Api.handle_event(event, :system_config_save_decision_model_config, nil)

    event = Events.build_invoke_event(%{}, :system_config_get_decision_model_config)

    assert Api.handle_event(event, :system_config_get_decision_model_config, nil).response ==
             config

    assert System.get_config("rag.decision.model") == nil
  end
end
