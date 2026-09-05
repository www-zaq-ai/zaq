defmodule Zaq.Agent.ProviderModelsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.ZAQRouter
  alias Zaq.System.AIProviderCredential

  defmodule FailingAvailabilityAdapter do
    def models(:openai), do: []
    def models(_), do: []
    def provider(_), do: :error
    def parse_provider(_), do: :error
    def available_models(_opts), do: raise("boom")
    def model(_), do: {:error, :unknown_model}
  end

  defmodule OpenRouterFallbackAdapter do
    def models(:openrouter) do
      [
        %LLMDB.Model{
          id: "openai/gpt-5.1-chat",
          provider: :openrouter,
          name: "GPT 5.1 Chat",
          deprecated: false,
          retired: false
        }
      ]
    end

    def models(_), do: []
    def provider(_), do: :error
    def parse_provider(_), do: :error
    def available_models(_opts), do: raise("boom")
    def model(_), do: {:error, :unknown_model}
  end

  defmodule CatalogOnlyAdapter do
    def models(:scaleway),
      do: [
        %LLMDB.Model{
          id: "mistral-small-3.2-24b-instruct-2506",
          provider: :scaleway,
          name: "Mistral Small",
          deprecated: false,
          retired: false
        }
      ]

    def models(:openai),
      do: [
        %LLMDB.Model{
          id: "gpt-4o",
          provider: :openai,
          name: "GPT-4o",
          deprecated: false,
          retired: false
        }
      ]

    def models(_), do: []
    def provider(:scaleway), do: {:ok, %LLMDB.Provider{id: :scaleway, catalog_only: true}}
    def provider(_), do: :error
    def parse_provider("scaleway"), do: {:ok, :scaleway}
    def parse_provider(_), do: :error

    def available_models(_opts),
      do: raise("catalog-only providers must not use runtime discovery")

    def model(_), do: {:error, :unknown_model}
  end

  defmodule CodexFallbackAdapter do
    def models(:openai), do: raise("boom")
    def models(_), do: []
    def provider(_), do: :error
    def parse_provider(_), do: :error
    def available_models(_opts), do: []

    def model("openai_codex:gpt-5.3-codex-spark"),
      do:
        {:ok,
         %LLMDB.Model{
           id: "gpt-5.3-codex-spark",
           provider: :openai_codex,
           deprecated: false,
           retired: false
         }}

    def model(_), do: {:error, :unknown_model}
  end

  defmodule MissingCodexAdapter do
    def models(:openai),
      do: [
        %LLMDB.Model{
          id: "missing-from-reqllm",
          provider: :openai,
          deprecated: false,
          retired: false
        }
      ]

    def models(_), do: []
    def provider(_), do: :error
    def parse_provider(_), do: :error
    def available_models(_opts), do: []

    def model(spec) do
      send(self(), {:reqllm_model_called, spec})
      {:error, :unknown_model}
    end
  end

  defmodule MissingAvailableModelAdapter do
    def models(:openai), do: []
    def models(_), do: []
    def provider(_), do: :error
    def parse_provider(_), do: :error

    def available_models(opts) do
      send(self(), {:reqllm_available_models_called, opts})
      ["openai:not-in-catalog"]
    end

    def model(spec) do
      send(self(), {:reqllm_model_called, spec})
      {:error, :unknown_model}
    end
  end

  defmodule AdapterConfig do
    def get(:zaq, :provider_models_adapter, default, opts),
      do: Keyword.get(opts, :provider_models_adapter, default)

    def get(app, key, default, _opts), do: Application.get_env(app, key, default)
  end

  defp adapter_opts(adapter), do: [config: AdapterConfig, provider_models_adapter: adapter]

  describe "models_for_credential/1 auth gating" do
    setup do
      on_exit(fn -> LLMDB.load(ZAQRouter.llmdb_opts()) end)
      {:ok, _} = ZAQRouter.reload(["openai/gpt-oss-120b", "deepseek/deepseek-v4-pro"])
      :ok
    end

    test "returns no models when the credential has no api key" do
      credential = %AIProviderCredential{provider: "zaq_router", endpoint: "https://llm.test/v1"}

      assert ProviderModels.models_for_credential(credential) == []
    end

    test "returns no models when the api key is blank" do
      credential = %AIProviderCredential{
        provider: "zaq_router",
        endpoint: "https://llm.test/v1",
        api_key: ""
      }

      assert ProviderModels.models_for_credential(credential) == []
    end

    test "returns the catalog once an api key is present" do
      credential = %AIProviderCredential{
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

  test "models returns [] for unsupported provider id types" do
    assert ProviderModels.models(123) == []
    assert ProviderModels.models(%{provider: "openai"}) == []
  end

  test "models returns [] for custom provider id" do
    assert ProviderModels.models("custom") == []
  end

  test "models returns [] for unknown provider atom name" do
    assert ProviderModels.models("unknown_provider") == []
  end

  test "models accepts provider atoms" do
    assert ProviderModels.models(:openai) |> Enum.any?(&(&1.id == "gpt-4o"))
  end

  test "models accepts display-case provider labels" do
    assert ProviderModels.models("OpenAI") |> Enum.any?(&(&1.id == "gpt-4o"))
    assert ProviderModels.models("Custom") == []
  end

  test "models_for_credential returns [] for display-case custom provider" do
    credential = %AIProviderCredential{
      provider: "Custom",
      endpoint: "https://custom-endpoint.com",
      api_key: "sk-test"
    }

    assert ProviderModels.models_for_credential(credential) == []
  end

  test "models_for_credential returns [] when credential does not expose a binary provider" do
    assert ProviderModels.models_for_credential(%{}) == []
    assert ProviderModels.models_for_credential(%{provider: :openai}) == []
  end

  test "models_for_credential returns [] for nil credential" do
    assert ProviderModels.models_for_credential(nil) == []
  end

  test "model_for_credential returns nil for nil or blank model id" do
    credential = %AIProviderCredential{provider: "openai", api_key: "sk-test"}

    assert ProviderModels.model_for_credential(credential, nil) == nil
    assert ProviderModels.model_for_credential(credential, "") == nil
  end

  test "model returns nil for nil or blank model id" do
    assert ProviderModels.model(:openai, nil) == nil
    assert ProviderModels.model("openai", "") == nil
  end

  test "model returns an openai model for a known model id" do
    assert ProviderModels.model("openai", "gpt-4o") |> Map.get(:id) == "gpt-4o"
  end

  test "model_for_credential returns an openai model for a known model id" do
    credential = %AIProviderCredential{provider: "openai", endpoint: "https://api.openai.com/v1"}

    assert ProviderModels.model_for_credential(credential, "gpt-4o") |> Map.get(:id) == "gpt-4o"
  end

  test "model and model_for_credential return nil for unknown model ids" do
    credential = %AIProviderCredential{provider: "openai", endpoint: "https://api.openai.com/v1"}

    assert ProviderModels.model("openai", "missing-model") == nil
    assert ProviderModels.model_for_credential(credential, "missing-model") == nil
  end

  test "models_for_credential uses ReqLLM availability for configured catalog providers" do
    credential = %AIProviderCredential{
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      api_key: "sk-test"
    }

    model_ids = credential |> ProviderModels.models_for_credential() |> Enum.map(& &1.id)

    assert "gpt-4o" in model_ids
  end

  test "models_for_credential falls back to provider models when availability lookup fails" do
    credential = %AIProviderCredential{
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      api_key: "sk-test"
    }

    assert ProviderModels.models_for_credential(
             credential,
             adapter_opts(FailingAvailabilityAdapter)
           ) == []
  end

  test "models_for_credential normalizes display-case provider labels before fallback" do
    credential = %AIProviderCredential{
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: "sk-test"
    }

    assert [%{id: "openai/gpt-5.1-chat", provider: :openrouter}] =
             ProviderModels.models_for_credential(
               credential,
               adapter_opts(OpenRouterFallbackAdapter)
             )
  end

  test "models_for_credential uses catalog models for catalog-only OpenAI-compatible providers" do
    credential = %AIProviderCredential{
      provider: "Scaleway",
      endpoint: "https://api.scaleway.ai/v1",
      api_key: "sk-test"
    }

    assert [%{id: "mistral-small-3.2-24b-instruct-2506", provider: :scaleway}] =
             ProviderModels.models_for_credential(credential, adapter_opts(CatalogOnlyAdapter))
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

  test "models returns ReqLLM fallback candidates when OpenAI catalog lookup fails" do
    models = ProviderModels.models("openai_codex", adapter_opts(CodexFallbackAdapter))

    assert [%{id: "gpt-5.3-codex-spark", provider: :openai_codex}] = models
  end

  test "models drops OpenAI Codex candidates that ReqLLM cannot resolve" do
    assert ProviderModels.models("openai_codex", adapter_opts(MissingCodexAdapter)) == []
    assert_received {:reqllm_model_called, "openai_codex:missing-from-reqllm"}
  end

  test "models_for_credential drops available model specs that ReqLLM cannot resolve" do
    credential = %AIProviderCredential{
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      api_key: "sk-test"
    }

    assert ProviderModels.models_for_credential(
             credential,
             adapter_opts(MissingAvailableModelAdapter)
           ) == []

    assert_received {:reqllm_available_models_called, _opts}
  end
end
