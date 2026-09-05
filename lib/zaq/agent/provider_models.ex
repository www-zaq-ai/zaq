defmodule Zaq.Agent.ProviderModels do
  @moduledoc """
  Resolves model metadata for AI providers shown in BO configuration screens.

  LLMDB remains the catalog source when a provider exists there. ReqLLM-only
  providers use a small candidate list and `ReqLLM.model/1` for validation and
  metadata enrichment when credential-scoped discovery is unavailable.
  """

  alias Zaq.Agent.ProviderSpec

  @reqllm_provider_model_candidates %{
    "openai_codex" => ["gpt-5.3-codex-spark"]
  }

  @doc "Normalizes provider labels and ids to the catalog id shape used by LLMDB."
  @spec normalize_provider_id(String.t() | atom() | nil) :: String.t() | nil
  def normalize_provider_id(nil), do: nil

  def normalize_provider_id(provider_id) when is_atom(provider_id) do
    provider_id
    |> Atom.to_string()
    |> normalize_provider_id()
  end

  def normalize_provider_id(provider_id) when is_binary(provider_id) do
    provider_id
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  def normalize_provider_id(_provider_id), do: nil

  @doc "Returns active model metadata for a provider."
  @spec models(String.t() | atom() | nil, keyword()) :: [LLMDB.Model.t()]
  def models(provider_id, opts \\ [])
  def models(provider_id, _opts) when provider_id in [nil, ""], do: []

  def models(provider_id, opts) when is_atom(provider_id) do
    provider_id
    |> normalize_provider_id()
    |> models(opts)
  end

  def models(provider_id, opts) when is_binary(provider_id) do
    provider_id = normalize_provider_id(provider_id)

    case provider_id do
      id when id in [nil, "", "custom"] -> []
      "openai_codex" -> openai_codex_fallback_models(opts)
      _ -> llmdb_provider_models(provider_id, opts)
    end
  end

  def models(_provider_id, _opts), do: []

  @doc "Returns active model metadata for one configured AI credential."
  @spec models_for_credential(Zaq.System.AIProviderCredential.t() | map() | nil, keyword()) :: [
          LLMDB.Model.t()
        ]
  def models_for_credential(credential, opts \\ [])
  def models_for_credential(nil, _opts), do: []

  def models_for_credential(%{provider: provider_id} = credential, opts)
      when is_binary(provider_id) do
    provider_id = normalize_provider_id(provider_id)

    cond do
      provider_id == "custom" ->
        []

      catalog_only_provider?(provider_id, opts) ->
        models(provider_id, opts)

      true ->
        normalized = normalize_credential_provider(credential, provider_id)

        normalized
        |> available_models_for_credential(opts)
        |> fallback_to_provider_models(provider_id, normalized, opts)
    end
  end

  def models_for_credential(_credential, _opts), do: []

  @doc "Returns model metadata for one configured AI credential/model pair."
  @spec model_for_credential(Zaq.System.AIProviderCredential.t() | map() | nil, String.t() | nil) ::
          LLMDB.Model.t() | nil
  def model_for_credential(_credential, model_id) when model_id in [nil, ""], do: nil

  def model_for_credential(credential, model_id) do
    credential
    |> models_for_credential()
    |> Enum.find(fn model -> model.id == model_id or Map.get(model, :model) == model_id end)
  end

  @doc "Returns model metadata for one provider/model pair, or nil when unknown."
  @spec model(String.t() | atom() | nil, String.t() | nil) :: LLMDB.Model.t() | nil
  def model(_provider_id, model_id) when model_id in [nil, ""], do: nil

  def model(provider_id, model_id) do
    provider_id
    |> normalize_provider_id()
    |> models()
    |> Enum.find(fn model -> model.id == model_id or Map.get(model, :model) == model_id end)
  end

  defp normalize_credential_provider(credential, provider_id) when is_binary(provider_id) do
    %{credential | provider: provider_id}
  end

  defp normalize_credential_provider(credential, _provider_id), do: credential

  defp reqllm_provider_models(provider_id, candidates, opts) do
    candidates
    |> Enum.map(&reqllm_model(provider_id, &1, opts))
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  end

  defp available_models_for_credential(%{provider: provider_id} = credential, opts) do
    provider = ProviderSpec.reqllm_provider(provider_id)

    credential
    |> ProviderSpec.credential_opts()
    |> Keyword.put(:scope, provider)
    |> adapter(opts).available_models()
    |> Enum.map(&reqllm_model(&1, opts))
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  rescue
    _ -> []
  end

  # `ReqLLM.available_models/1` returns [] both when a provider's catalog cannot
  # be enumerated and when the credential carries no resolvable key. The
  # full-catalog fallback covers the first case, and keeps the model picker
  # populated while a credential is still being filled in — most providers are
  # selected before their key is entered, and OAuth credentials (openai_codex)
  # legitimately resolve no api_key at all.
  #
  # ZAQ Router is the exception: it is a hosted gateway that always requires both
  # an endpoint and a key, so a credential without one means "not configured yet"
  # and must advertise no models rather than a catalog it cannot reach.
  defp fallback_to_provider_models([], provider_id, credential, opts) do
    if zaq_router?(provider_id) and not credential_auth_present?(credential) do
      []
    else
      models(provider_id, opts)
    end
  end

  defp fallback_to_provider_models(models, _provider_id, _credential, _opts), do: models

  defp zaq_router?(provider_id), do: provider_id == "zaq_router"

  # Mirrors what ReqLLM.Keys/Auth resolve from: credential_opts/1 omits blank
  # api keys and tokens, so key presence is equivalent to a usable value.
  defp credential_auth_present?(credential) do
    opts = ProviderSpec.credential_opts(credential)

    Keyword.has_key?(opts, :api_key) or Keyword.has_key?(opts, :access_token)
  rescue
    _ -> false
  end

  defp catalog_only_provider?(provider_id, opts) when is_binary(provider_id) do
    adapter = adapter(opts)

    with {:ok, atom} <- adapter.parse_provider(provider_id),
         {:ok, %LLMDB.Provider{catalog_only: true}} <- adapter.provider(atom) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp catalog_only_provider?(_provider_id, _opts), do: false

  defp openai_codex_fallback_models(opts) do
    openai_models_as_codex(opts)
    |> Kernel.++(
      reqllm_provider_models(
        "openai_codex",
        @reqllm_provider_model_candidates["openai_codex"],
        opts
      )
    )
    |> Enum.uniq_by(& &1.id)
  end

  defp openai_models_as_codex(opts) do
    :openai
    |> adapter(opts).models()
    |> Enum.reject(&deprecated_or_retired?/1)
    |> Enum.map(&reqllm_model("openai_codex", &1.id, opts))
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  rescue
    _ -> []
  end

  defp llmdb_provider_models(provider_id, opts) do
    provider_atom = String.to_existing_atom(provider_id)

    provider_atom
    |> adapter(opts).models()
    |> Enum.reject(&deprecated_or_retired?/1)
  rescue
    ArgumentError -> []
  end

  defp reqllm_model(provider_id, model_id, opts) do
    case adapter(opts).model("#{provider_id}:#{model_id}") do
      {:ok, model} -> model
      _ -> nil
    end
  end

  defp reqllm_model(model_spec, opts) when is_binary(model_spec) do
    case adapter(opts).model(model_spec) do
      {:ok, model} -> model
      _ -> nil
    end
  end

  defp adapter(opts) do
    Zaq.Config.get(:zaq, :provider_models_adapter, __MODULE__.Adapter, opts)
  end

  defp deprecated_or_retired?(model), do: model.deprecated or model.retired
end

defmodule Zaq.Agent.ProviderModels.Adapter do
  @moduledoc false

  def models(provider), do: LLMDB.models(provider)
  def provider(provider), do: LLMDB.provider(provider)
  def parse_provider(provider), do: LLMDB.Spec.parse_provider(provider)
  def available_models(opts), do: ReqLLM.available_models(opts)
  def model(spec), do: ReqLLM.model(spec)
end
