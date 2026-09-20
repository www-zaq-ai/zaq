defmodule Zaq.Engine.Connect.AIRuntimeCredentialsTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Engine.Connect.AIRuntimeCredentials

  @actor %{kind: :system, subject: "ai-runtime-credentials-test"}

  test "loads provider configuration and resolves authentication inside Engine" do
    credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://runtime.example.com/v1",
        api_key: "runtime-secret",
        metadata: %{"region" => "eu"}
      })

    assert {:ok, %{credential: projected, resolved_credential: resolved}} =
             AIRuntimeCredentials.resolve(credential.id, @actor)

    assert projected == %{
             id: credential.id,
             provider: "openai",
             endpoint: "https://runtime.example.com/v1",
             metadata: %{"region" => "eu"},
             sovereign: false,
             connect_credential_id: credential.connect_credential_id
           }

    refute Map.has_key?(projected, :api_key)
    assert resolved.authentication == %{api_key: "runtime-secret"}
  end

  test "requires a validated execution actor" do
    assert AIRuntimeCredentials.resolve(1, nil) == {:error, :missing_execution_actor}
    assert AIRuntimeCredentials.resolve(1, %{}) == {:error, :invalid_execution_actor}
  end

  test "preserves the prior missing provider configuration result" do
    assert AIRuntimeCredentials.resolve(0, @actor) == {:ok, nil}
  end
end
