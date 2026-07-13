defmodule Zaq.Agent.ProviderModelsTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.ProviderModels
  alias Zaq.System.AIProviderCredential

  test "models_for_credential uses ReqLLM availability for configured catalog providers" do
    credential = %AIProviderCredential{
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      api_key: "sk-test"
    }

    model_ids = credential |> ProviderModels.models_for_credential() |> Enum.map(& &1.id)

    assert "gpt-4o" in model_ids
  end

  test "models_for_credential falls back to OpenAI catalog models resolved as Codex" do
    credential = %AIProviderCredential{
      provider: "openai_codex",
      endpoint: "https://chatgpt.com/backend-api",
      metadata: %{"auth_kind" => "oauth2"}
    }

    models = ProviderModels.models_for_credential(credential)
    model_ids = Enum.map(models, & &1.id)

    assert "gpt-5.3-codex-spark" in model_ids
    assert "text-embedding-3-small" in model_ids

    assert Enum.all?(models, &(&1.provider == :openai_codex))
  end
end
