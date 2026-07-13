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
  alias Zaq.System
  require Logger

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
  # ZAQ Provider is a LiteLLM gateway — always route through OpenAI-compatible protocol.
  def reqllm_provider(p) when p in [:zaq_router, "zaq_router"], do: :openai

  def reqllm_provider(:openai_codex), do: :openai_codex
  def reqllm_provider("openai_codex"), do: :openai_codex

  def reqllm_provider(p) do
    with {:ok, atom} <- reqllm_provider_atom(p),
         {:ok, _provider_module} <- ReqLLM.provider(atom) do
      atom
    else
      _ -> reqllm_provider_from_llmdb(p)
    end
  end

  defp reqllm_provider_from_llmdb(p) do
    with {:ok, atom} <- LLMDB.Spec.parse_provider(p),
         {:ok, %LLMDB.Provider{catalog_only: false}} <- LLMDB.provider(atom),
         {:ok, _provider_module} <- ReqLLM.provider(atom) do
      atom
    else
      _ -> :openai
    end
  end

  defp reqllm_provider_atom(provider) when is_atom(provider), do: {:ok, provider}

  defp reqllm_provider_atom(provider) when is_binary(provider) do
    {:ok, String.to_existing_atom(provider)}
  rescue
    ArgumentError -> :error
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
  Builds a ReqLLM model spec map from the system LLM config.
  """
  def build do
    System.get_llm_config() |> build()
  end

  @doc """
  Builds a ReqLLM model spec map.

  Accepts either a system LLM config map (`%{provider:, model:, ...}`) or a
  `ConfiguredAgent`. Pass a pre-fetched config map when the config has already
  been read to avoid a redundant `get_llm_config/0` call.

  For a `ConfiguredAgent`, resolves the provider via LLMDB and the agent's
  credential, falling back to `:openai` for OpenAI-compatible custom endpoints.
  """
  def build(arg)

  def build(%{provider: _, model: _} = cfg) do
    provider = reqllm_provider(cfg.provider)

    %{provider: provider, id: cfg.model}
    |> put_base_url(cfg)
  end

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

  @doc """
  Builds sampling keyword opts for ReqLLM generation calls from a config map.

  Includes `temperature`, `top_p`, `api_key` (when present), and `openai_logprobs`
  when the config reports logprob support and the provider resolves to `:openai`.
  Accepts any map with the same shape as the system LLM config or a per-agent config.
  """
  def generation_opts(cfg) do
    opts = [temperature: cfg.temperature, top_p: cfg.top_p]

    if is_binary(cfg.api_key) and cfg.api_key != "" do
      Keyword.put(opts, :api_key, cfg.api_key)
    else
      opts
    end

    # This is how we were handleing logprobs before
    # if cfg.supports_logprobs and reqllm_provider(cfg.provider) == :openai do
    #   Keyword.put(opts, :provider_options, openai_logprobs: true)
    # else
    #   opts
    # end
  end

  @doc """
  Builds the default `advanced_options` map for a system LLM config.

  Enables `openai_logprobs` when the provider resolves to `:openai` and the
  config reports logprob support.
  """
  def default_advanced_options(%{supports_logprobs: true} = cfg) do
    if reqllm_provider(cfg.provider) == :openai do
      %{provider_options: [openai_logprobs: true]}
    else
      %{}
    end
  end

  def default_advanced_options(_cfg), do: %{}

  @doc """
  Builds ReqLLM keyword opts for a configured agent.

  Converts the agent's `advanced_options` map to a keyword list, then merges
  in `api_key` and `base_url` from the resolved credential.
  """
  @spec llm_opts(ConfiguredAgent.t()) :: keyword()
  def llm_opts(%ConfiguredAgent{} = configured_agent) do
    credential = resolve_credential(configured_agent)

    configured_agent
    |> advanced_options_as_keyword()
    |> put_credential_opts(credential)
  end

  @doc """
  Builds ReqLLM keyword opts from one AI provider credential.
  """
  @spec credential_opts(Zaq.System.AIProviderCredential.t() | map() | nil) :: keyword()
  def credential_opts(credential), do: put_credential_opts([], credential)

  defp put_credential_opts(opts, %{provider: "openai_codex"} = credential) do
    token = credential_oauth_token(credential)
    metadata = credential_metadata(credential)

    opts
    |> maybe_put(:access_token, token)
    |> maybe_put(:auth_mode, :oauth)
    |> maybe_put(:base_url, codex_base_url(metadata))
    |> put_codex_provider_options(metadata)
  end

  defp put_credential_opts(opts, credential) do
    opts
    |> maybe_put(:api_key, credential_api_key(credential))
    |> maybe_put(:base_url, credential && credential.endpoint)
  end

  defp credential_oauth_token(%Zaq.System.AIProviderCredential{} = credential),
    do: System.resolve_ai_provider_api_key(credential)

  defp credential_oauth_token(%{access_token: token}), do: token
  defp credential_oauth_token(%{"access_token" => token}), do: token
  defp credential_oauth_token(_), do: nil

  defp credential_api_key(%Zaq.System.AIProviderCredential{} = credential),
    do: System.resolve_ai_provider_api_key(credential)

  defp credential_api_key(%{api_key: api_key}), do: api_key
  defp credential_api_key(%{"api_key" => api_key}), do: api_key
  defp credential_api_key(_), do: nil

  defp credential_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp credential_metadata(_), do: %{}

  defp codex_base_url(metadata) do
    metadata_value(metadata, "backend_base_url") || "https://chatgpt.com/backend-api"
  end

  defp put_codex_provider_options(opts, metadata) do
    provider_options = Keyword.get(opts, :provider_options, [])

    provider_options =
      provider_options
      |> Keyword.put_new(:auth_mode, :oauth)
      |> maybe_put(:codex_originator, codex_originator(metadata))
      |> maybe_put(:chatgpt_account_id, metadata_value(metadata, "chatgpt_account_id"))

    Keyword.put(opts, :provider_options, provider_options)
  end

  defp codex_originator(metadata) do
    metadata
    |> metadata_value("authorize_params")
    |> case do
      %{} = params -> metadata_value(params, "originator")
      _ -> nil
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, existing_atom_key(key))

  defp metadata_value(_metadata, _key), do: nil

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp resolve_credential(%ConfiguredAgent{credential: credential}) when not is_nil(credential),
    do: credential

  defp resolve_credential(%ConfiguredAgent{credential_id: id}) when is_integer(id),
    do: Zaq.System.get_ai_provider_credential(id)

  defp resolve_credential(_), do: nil

  defp advanced_options_as_keyword(%ConfiguredAgent{advanced_options: options})
       when is_map(options) do
    options
    |> Enum.reduce([], fn {key, value}, acc ->
      case normalize_option_key(key) do
        nil -> acc
        atom_key -> [{atom_key, value} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp advanced_options_as_keyword(_), do: []

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError ->
      Logger.warning("Ignoring unsupported advanced option key: #{inspect(key)}")
      nil
  end

  defp normalize_option_key(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
