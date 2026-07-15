defmodule Zaq.Agent.ProviderModelsTest do
  use ExUnit.Case, async: false

  alias Zaq.Agent.ProviderModels
  alias Zaq.System.AIProviderCredential

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

    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :deprecated, :retired]
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
           def models(:openai), do: []
           def models(_), do: []
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def available_models(_opts), do: raise("boom")
           def model(_), do: {:error, :unknown_model}
         end
         """}
      ],
      fn ->
        assert ProviderModels.models_for_credential(credential) == []
      end
    )
  end

  test "models_for_credential normalizes display-case provider labels before fallback" do
    credential = %AIProviderCredential{
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: "sk-test"
    }

    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :name, :deprecated, :retired]
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
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
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def provider(_), do: {:error, :unknown_provider}
           def available_models(_opts), do: raise("boom")
           def model(_), do: {:error, :unknown_model}
         end
         """},
        {Zaq.Agent.ProviderSpec,
         """
         defmodule Zaq.Agent.ProviderSpec do
           def reqllm_provider(_provider), do: :openai
           def credential_opts(_credential), do: []
         end
         """}
      ],
      fn ->
        assert [%{id: "openai/gpt-5.1-chat", provider: :openrouter}] =
                 ProviderModels.models_for_credential(credential)
      end
    )
  end

  test "models_for_credential uses catalog models for catalog-only OpenAI-compatible providers" do
    credential = %AIProviderCredential{
      provider: "Scaleway",
      endpoint: "https://api.scaleway.ai/v1",
      api_key: "sk-test"
    }

    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :name, :deprecated, :retired]
         end
         """},
        {LLMDB.Provider,
         """
         defmodule LLMDB.Provider do
           defstruct [:id, :catalog_only]
         end
         """},
        {LLMDB.Spec,
         """
         defmodule LLMDB.Spec do
           def parse_provider("scaleway"), do: {:ok, :scaleway}
           def parse_provider(_), do: :error
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
           def provider(:scaleway), do: {:ok, %LLMDB.Provider{id: :scaleway, catalog_only: true}}

           def models(:scaleway) do
             [
               %LLMDB.Model{
                 id: "mistral-small-3.2-24b-instruct-2506",
                 provider: :scaleway,
                 name: "Mistral Small",
                 deprecated: false,
                 retired: false
               }
             ]
           end

           def models(:openai) do
             [
               %LLMDB.Model{
                 id: "gpt-4o",
                 provider: :openai,
                 name: "GPT-4o",
                 deprecated: false,
                 retired: false
               }
             ]
           end

           def models(_), do: []
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def available_models(_opts), do: raise("catalog-only providers must not use runtime discovery")
           def model(_), do: {:error, :unknown_model}
         end
         """}
      ],
      fn ->
        assert [%{id: "mistral-small-3.2-24b-instruct-2506", provider: :scaleway}] =
                 ProviderModels.models_for_credential(credential)
      end
    )
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
    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :deprecated, :retired]
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
           def models(:openai), do: raise("boom")
           def models(_), do: []
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def model("openai_codex:gpt-5.3-codex-spark") do
             {:ok,
              %LLMDB.Model{
                id: "gpt-5.3-codex-spark",
                provider: :openai_codex,
                deprecated: false,
                retired: false
              }}
           end

           def model(_), do: {:error, :unknown_model}
         end
         """}
      ],
      fn ->
        models = ProviderModels.models("openai_codex")

        assert [%{id: "gpt-5.3-codex-spark", provider: :openai_codex}] = models
      end
    )
  end

  test "models drops OpenAI Codex candidates that ReqLLM cannot resolve" do
    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :deprecated, :retired]
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
           def models(:openai) do
             [
               %LLMDB.Model{
                 id: "missing-from-reqllm",
                 provider: :openai,
                 deprecated: false,
                 retired: false
               }
             ]
           end

           def models(_), do: []
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def model(spec) do
             send(self(), {:reqllm_model_called, spec})
             {:error, :unknown_model}
           end
         end
         """}
      ],
      fn ->
        assert ProviderModels.models("openai_codex") == []
        assert_received {:reqllm_model_called, "openai_codex:missing-from-reqllm"}
      end
    )
  end

  test "models_for_credential drops available model specs that ReqLLM cannot resolve" do
    credential = %AIProviderCredential{
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      api_key: "sk-test"
    }

    with_temporary_modules(
      [
        {LLMDB.Model,
         """
         defmodule LLMDB.Model do
           defstruct [:id, :provider, :deprecated, :retired]
         end
         """},
        {LLMDB,
         """
         defmodule LLMDB do
           def models(:openai), do: []
           def models(_), do: []
         end
         """},
        {ReqLLM,
         """
         defmodule ReqLLM do
           def available_models(opts) do
             send(self(), {:reqllm_available_models_called, opts})
             ["openai:not-in-catalog"]
           end

           def model(spec) do
             send(self(), {:reqllm_model_called, spec})
             {:error, :unknown_model}
           end
         end
         """}
      ],
      fn ->
        assert ReqLLM.available_models([]) == ["openai:not-in-catalog"]
        assert ProviderModels.models_for_credential(credential) == []
        assert_received {:reqllm_available_models_called, _opts}
      end
    )
  end

  defp with_temporary_modules(stubs, fun) when is_list(stubs) and is_function(fun, 0) do
    original_paths =
      Enum.into(stubs, %{}, fn {module, _source} ->
        {module, :code.which(module)}
      end)

    Enum.each(stubs, fn {module, _source} ->
      purge_module(module)
    end)

    try do
      Enum.each(stubs, fn {_module, source} ->
        Code.compile_string(source)
      end)

      fun.()
    after
      Enum.each(Enum.map(stubs, &elem(&1, 0)) |> Enum.reverse(), &purge_module/1)

      Enum.each(original_paths, fn {module, original_path} ->
        restore_module(module, original_path)
      end)
    end
  end

  defp purge_module(module) do
    :code.purge(module)
    :code.delete(module)
  end

  defp restore_module(_module, path) when path in [:non_existing, :preloaded, nil], do: :ok

  defp restore_module(_module, path) do
    path
    |> to_string()
    |> Path.rootname()
    |> String.to_charlist()
    |> :code.load_abs()

    :ok
  end
end
