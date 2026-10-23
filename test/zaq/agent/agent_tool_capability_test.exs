defmodule Zaq.AgentToolCapabilityTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  test "confirmed unsupported model capability blocks configured tools" do
    Zaq.UnsupportedModelFixture.install()

    credential =
      ai_credential_fixture(%{
        name:
          "Agent Unsupported Tools Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai"
      })

    {:error, changeset} =
      Zaq.Agent.create_agent(%{
        name: "Unsupported Tools Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "qwen/qwen3-4b-fp8",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["general.encode_json"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert "selected model does not support tool calling" in errors_on(changeset).enabled_tool_keys
  end
end
