defmodule Zaq.Agent.ProviderModelsCatalogTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.ZAQRouter
  alias Zaq.System.AIProviderCredential
  alias Zaq.TestSupport.ModelCatalogFixture

  # These cases only read this fixture. Load it once while synchronous execution
  # excludes other catalog readers/writers, then restore the original snapshot.
  setup_all do
    snapshot = LLMDB.Store.snapshot()
    opts = LLMDB.Store.last_opts()

    on_exit(fn ->
      if snapshot, do: LLMDB.Store.put!(snapshot, opts), else: LLMDB.Store.clear!()
    end)

    catalog_opts = ModelCatalogFixture.minimal_source_opts!()

    {:ok, _} =
      ZAQRouter.reload(["openai/gpt-oss-120b", "deepseek/deepseek-v4-pro"], catalog_opts)

    :ok
  end

  describe "models_for_credential/1 auth gating" do
    test "returns no models when the credential has no api key" do
      credential = %{provider: "zaq_router", endpoint: "https://llm.test/v1"}

      assert ProviderModels.models_for_credential(credential) == []
    end

    test "returns no models when the api key is blank" do
      credential = %{
        provider: "zaq_router",
        endpoint: "https://llm.test/v1",
        api_key: ""
      }

      assert ProviderModels.models_for_credential(credential) == []
    end

    test "returns the catalog once an api key is present" do
      credential = %{
        provider: "zaq_router",
        endpoint: "https://llm.test/v1",
        api_key: "sk-test-123"
      }

      model_ids = credential |> ProviderModels.models_for_credential() |> Enum.map(& &1.id)

      assert "openai/gpt-oss-120b" in model_ids
      assert "deepseek/deepseek-v4-pro" in model_ids
    end

    test "gating is scoped to zaq_router — other providers keep the fallback" do
      openai = %AIProviderCredential{provider: "openai"}

      refute ProviderModels.models_for_credential(openai) == []
    end

    test "gating does not strip models from OAuth credentials without an api key" do
      codex = %AIProviderCredential{
        provider: "openai_codex",
        endpoint: "https://chatgpt.com/backend-api",
        metadata: %{"auth_kind" => "oauth2"}
      }

      refute ProviderModels.models_for_credential(codex) == []
    end
  end
end
