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

  @doc "Returns active model metadata for a provider."
  @spec models(String.t() | atom() | nil) :: [LLMDB.Model.t()]
  def models(provider_id)
  def models(provider_id) when provider_id in [nil, "", "custom"], do: []

  def models(provider_id) when is_atom(provider_id) do
    provider_id
    |> Atom.to_string()
    |> models()
  end

  def models(provider_id) when is_binary(provider_id) do
    case provider_id do
      "openai_codex" -> openai_codex_fallback_models()
      _ -> llmdb_provider_models(provider_id)
    end
  end

  def models(_provider_id), do: []

  @doc "Returns active model metadata for one configured AI credential."
  @spec models_for_credential(Zaq.System.AIProviderCredential.t() | map() | nil) :: [
          LLMDB.Model.t()
        ]
  def models_for_credential(nil), do: []

  def models_for_credential(%{provider: provider_id} = credential) when is_binary(provider_id) do
    credential
    |> available_models_for_credential()
    |> fallback_to_provider_models(provider_id)
  end

  def models_for_credential(_credential), do: []

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
    |> models()
    |> Enum.find(fn model -> model.id == model_id or Map.get(model, :model) == model_id end)
  end

  defp reqllm_provider_models(provider_id, candidates) do
    candidates
    |> Enum.map(&reqllm_model(provider_id, &1))
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  end

  defp available_models_for_credential(%{provider: provider_id} = credential) do
    provider = ProviderSpec.reqllm_provider(provider_id)

    credential
    |> ProviderSpec.credential_opts()
    |> Keyword.put(:scope, provider)
    |> ReqLLM.available_models()
    |> Enum.map(&reqllm_model/1)
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  rescue
    _ -> []
  end

  defp fallback_to_provider_models([], provider_id), do: models(provider_id)
  defp fallback_to_provider_models(models, _provider_id), do: models

  defp openai_codex_fallback_models do
    openai_models_as_codex()
    |> Kernel.++(
      reqllm_provider_models("openai_codex", @reqllm_provider_model_candidates["openai_codex"])
    )
    |> Enum.uniq_by(& &1.id)
  end

  defp openai_models_as_codex do
    :openai
    |> LLMDB.models()
    |> Enum.reject(&deprecated_or_retired?/1)
    |> Enum.map(&reqllm_model("openai_codex", &1.id))
    |> Enum.reject(&(is_nil(&1) or deprecated_or_retired?(&1)))
  rescue
    _ -> []
  end

  defp llmdb_provider_models(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)

    provider_atom
    |> LLMDB.models()
    |> Enum.reject(&deprecated_or_retired?/1)
  rescue
    ArgumentError -> []
  end

  defp reqllm_model(provider_id, model_id) do
    case ReqLLM.model("#{provider_id}:#{model_id}") do
      {:ok, model} -> model
      _ -> nil
    end
  end

  defp reqllm_model(model_spec) when is_binary(model_spec) do
    case ReqLLM.model(model_spec) do
      {:ok, model} -> model
      _ -> nil
    end
  end

  defp deprecated_or_retired?(model), do: model.deprecated or model.retired
end
