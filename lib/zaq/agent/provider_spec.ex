defmodule Zaq.Agent.ProviderSpec do
  @moduledoc """
  Translates AIProviderCredential and system LLM config into ReqLLM model spec maps.

  Centralises all provider-identity normalization (`reqllm_provider/1`,
  `fixed_url_provider?/1`) and base-URL injection logic that was previously
  scattered across `Factory`.

  `Factory` is the only caller for model spec assembly. Other modules should use
  `Factory.build_model_spec/0,1` rather than calling this module directly.
  """

  alias Zaq.Agent.ConfiguredAgent

  # Providers that manage their own base URL inside ReqLLM — never override with a custom base_url.
  # This list cannot be derived automatically from the llm_db catalog: the catalog's `base_url`
  # field marks a provider's default endpoint, not whether it is user-overridable. For example,
  # both `openai` (overridable) and `anthropic` (not overridable) have `base_url` in the catalog.
  @fixed_url_providers ~w(anthropic google xai mistral)a

  @doc """
  Maps a provider string or atom to the atom ReqLLM expects.

  Looks up the provider in the llm_db catalog. If found and not `catalog_only`,
  returns the catalog atom — ReqLLM handles it natively. `catalog_only` providers
  have no direct API endpoint managed by ReqLLM and fall back to `:openai` for
  OpenAI-compatible routing. Also falls back for unknown providers.
  """
  def reqllm_provider(p) do
    with {:ok, atom} <- LLMDB.Spec.parse_provider(p),
         {:ok, %LLMDB.Provider{catalog_only: false}} <- LLMDB.provider(atom) do
      atom
    else
      _ -> :openai
    end
  end

  @doc """
  Returns `true` if the provider manages its own base URL inside ReqLLM.

  Callers must NOT supply a `base_url` for these providers — ReqLLM uses its
  built-in default endpoint. Accepts both atoms (`:anthropic`) and strings
  (`"anthropic"`).
  """
  def fixed_url_provider?(provider) when is_atom(provider),
    do: provider in @fixed_url_providers

  def fixed_url_provider?(provider) when is_binary(provider) do
    fixed_url_provider?(String.to_existing_atom(provider))
  rescue
    ArgumentError -> false
  end

  @doc """
  Builds a ReqLLM model spec map for a configured agent.

  Resolves the provider via LLMDB and the agent's credential. Falls back to
  `:openai` when the provider is unknown to LLMDB but the credential carries a
  custom endpoint — indicating an intentional OpenAI-compatible deployment.
  """
  @spec build(ConfiguredAgent.t()) :: {:ok, map()} | {:error, atom()}
  def build(%ConfiguredAgent{} = configured_agent) do
    credential =
      configured_agent.credential ||
        Zaq.System.get_ai_provider_credential(configured_agent.credential_id)

    with {:ok, runtime_provider} <- resolve_configured_provider(configured_agent, credential) do
      spec = %{provider: runtime_provider, id: configured_agent.model}
      {:ok, put_base_url(spec, runtime_provider, credential)}
    end
  end

  @doc """
  Conditionally sets `:base_url` on a spec from system LLM config.

  Skips providers that manage their own URL inside ReqLLM.
  """
  def put_base_url(spec, %{provider: p} = cfg) do
    if fixed_url_provider?(reqllm_provider(p)) do
      spec
    else
      case cfg do
        %{endpoint: url} when is_binary(url) and url != "" -> Map.put(spec, :base_url, url)
        _ -> spec
      end
    end
  end

  def put_base_url(spec, _), do: spec

  @doc """
  Conditionally sets `:base_url` on a spec from a resolved provider atom and credential.

  Used when the provider has already been normalised via `reqllm_provider/1`.
  """
  def put_base_url(spec, provider, credential) when is_atom(provider) do
    if fixed_url_provider?(provider) do
      spec
    else
      case credential do
        %{endpoint: url} when is_binary(url) and url != "" -> Map.put(spec, :base_url, url)
        _ -> spec
      end
    end
  end

  # Falls back to :openai only when the provider is unknown to both ReqLLM and LLMDB
  # but the credential carries an explicit endpoint — signals an intentional
  # OpenAI-compatible custom deployment.
  defp resolve_configured_provider(configured_agent, credential) do
    case Zaq.Agent.runtime_provider_for_agent(configured_agent) do
      {:ok, _} = ok -> ok
      {:error, :provider_not_found} -> openai_if_custom_endpoint(credential)
      error -> error
    end
  end

  defp openai_if_custom_endpoint(%{endpoint: url}) when is_binary(url) and url != "",
    do: {:ok, :openai}

  defp openai_if_custom_endpoint(_), do: {:error, :provider_not_found}
end
