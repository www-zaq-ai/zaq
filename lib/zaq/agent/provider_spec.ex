defmodule Zaq.Agent.ProviderSpec do
  @moduledoc """
  Generic facade translating AI provider configuration into ReqLLM model specs/options.

  Provider-specific endpoint and authentication translation is selected through
  `Zaq.Agent.ProviderSpec.Registry`; this module owns orchestration and public contracts.
  Connect remains responsible for authorization, grant selection and OAuth identity.

  Factory owns configured-agent model assembly. ProviderModels and system generation
  consumers use the narrower public option/configuration functions directly.
  """

  alias ReqLLM.Provider.Adapter
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ProviderSpec.Registry
  alias Zaq.Engine.Connect.ResolvedCredential
  alias Zaq.System
  alias Zaq.Utils.Map, as: MapUtils
  require Logger

  @doc """
  Returns whether a provider is catalogued or has a registered runtime adapter.

  Accepts case-insensitive strings and atoms without creating atoms. Recognition
  does not imply model support; an unknown custom endpoint can still use a
  compatibility adapter without becoming a known provider.
  """
  @spec known_provider?(term()) :: boolean()
  def known_provider?(provider) when is_atom(provider),
    do: known_provider?(Atom.to_string(provider))

  def known_provider?(provider) when is_binary(provider) do
    case provider_atom(provider) do
      {:ok, atom} ->
        match?({:ok, _}, LLMDB.provider(atom)) or match?({:ok, _}, ReqLLM.provider(atom))

      {:error, _} ->
        false
    end
  end

  def known_provider?(_provider), do: false

  @doc """
  Maps a provider string or atom to the atom ReqLLM expects.

  Looks up the provider in the llm_db catalog. If found and not `catalog_only`,
  returns the catalog atom — ReqLLM handles it natively. `catalog_only` providers
  have no direct API endpoint managed by ReqLLM and fall back to `:openai` for
  OpenAI-compatible routing. Also falls back for unknown providers.
  """
  def reqllm_provider(provider) do
    implementation = Registry.fetch(provider)
    implementation.reqllm_provider(provider)
  end

  @doc """
  Returns `true` if the provider manages its own base URL inside ReqLLM.

  Callers must NOT supply a `base_url` for these providers — ReqLLM uses its
  built-in default endpoint. Accepts both atoms (`:anthropic`) and strings
  (`"anthropic"`).
  """
  def fixed_url_provider?(provider) do
    implementation = Registry.fetch(provider)
    implementation.fixed_url_provider?(provider)
  end

  @doc "Builds a dedicated operation runtime using canonical global authentication, never global LLM defaults."
  @spec operation_runtime(map()) :: {:ok, map(), keyword()} | {:error, term()}
  def operation_runtime(config), do: operation_runtime(config, :generation)

  @doc """
  Builds operation-appropriate options using canonical global authentication.

  Reranking preserves catalog model identity and execution metadata, including
  providers supported through ReqLLM's shared execution adapters. Generation
  uses the selected model's chat capability and configured-agent compatibility
  rules, not a provider-wide executable flag.
  """
  @spec operation_runtime(map(), :generation | :reranking | :evaluation) ::
          {:ok, map(), keyword()} | {:error, term()}
  def operation_runtime(config, operation)
      when operation in [:generation, :reranking, :evaluation] do
    with id when is_integer(id) <- config.credential_id,
         model when is_binary(model) and model != "" <- config.model,
         credential when not is_nil(credential) <- System.get_ai_provider_credential(id),
         {:ok, resolved} <- System.resolve_ai_provider_authentication(credential) do
      agent = %ConfiguredAgent{
        credential_id: id,
        credential: credential,
        model: model,
        temperature: Map.get(config, :temperature, 0.0),
        top_p: Map.get(config, :top_p, 0.9)
      }

      with {:ok, spec} <- operation_spec(operation, agent),
           {:ok, opts} <- llm_opts(agent, resolved) do
        operation_options(operation, spec, opts)
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :model_not_configured}
    end
  end

  defp operation_spec(:generation, agent), do: build(agent)

  defp operation_spec(:evaluation, %ConfiguredAgent{credential: credential, model: id}) do
    with {:ok, provider} <- LLMDB.Spec.parse_provider(credential.provider),
         {:ok, model} <- LLMDB.model(provider, id) do
      {:ok, put_base_url(Map.from_struct(model), model.provider, credential)}
    end
  end

  defp operation_spec(:reranking, %ConfiguredAgent{credential: credential, model: id} = agent) do
    with {:ok, provider} <- LLMDB.Spec.parse_provider(credential.provider),
         {:ok, model} <- LLMDB.model(provider, id) do
      {:ok, put_base_url(Map.from_struct(model), model.provider, credential)}
    else
      {:error, _} ->
        build(agent)
    end
  end

  defp operation_options(:generation, spec, opts), do: {:ok, spec, opts}

  defp operation_options(:evaluation, spec, opts) do
    with {:ok, model} <- ReqLLM.model(spec),
         {:ok, _adapter} <- Adapter.resolve(model, :evaluate) do
      {:ok, model, Keyword.drop(opts, [:temperature, :top_p])}
    end
  end

  defp operation_options(:reranking, spec, opts) do
    with {:ok, model} <- ReqLLM.Rerank.validate_model(spec) do
      {:ok, model, Keyword.drop(opts, [:temperature, :top_p])}
    end
  end

  @doc """
  Builds a ReqLLM model spec map.

  Accepts either an explicit config map (`%{provider:, model:, ...}`) or a
  `ConfiguredAgent`.

  For a `ConfiguredAgent`, resolves the provider via LLMDB and the agent's
  credential. Known non-chat models are rejected. Native adapters retain their
  identity; catalog-only chat models require an explicit endpoint to use the
  existing OpenAI-compatible path, regardless of other operations their provider
  supports. Unknown providers still require an explicit custom endpoint.
  """
  def build(arg)

  def build(%{provider: _, model: _} = cfg) do
    provider = reqllm_provider(cfg.provider)

    %{provider: provider, id: cfg.model}
    |> put_base_url(cfg)
  end

  @spec build(ConfiguredAgent.t()) :: {:ok, map()} | {:error, atom()}
  def build(%ConfiguredAgent{} = configured_agent) do
    credential = resolve_credential(configured_agent)

    with {:ok, runtime_provider} <-
           resolve_generation_provider(credential, configured_agent.model) do
      spec = %{provider: runtime_provider, id: configured_agent.model}
      {:ok, put_base_url(spec, runtime_provider, credential)}
    end
  end

  @doc """
  Conditionally sets `:base_url` on a spec from system LLM config.

  Skips providers that manage their own URL inside ReqLLM.
  """
  def put_base_url(spec, %{provider: p} = cfg) do
    implementation = Registry.fetch(p)

    implementation.put_model_spec(spec, %{
      provider: p,
      runtime_provider: implementation.reqllm_provider(p),
      endpoint: Map.get(cfg, :endpoint),
      metadata: Map.get(cfg, :metadata, %{}),
      auth_kind: nil,
      authentication: %{},
      runtime_identity: %{}
    })
  end

  def put_base_url(spec, _), do: spec

  @doc """
  Conditionally sets `:base_url` on a spec from a resolved provider atom and credential.

  Used when the provider has already been normalised via `reqllm_provider/1`.
  """
  def put_base_url(spec, provider, credential) when is_atom(provider) do
    context = model_context(credential, provider)
    implementation = Registry.fetch(context.provider)
    implementation.put_model_spec(spec, context)
  end

  defp resolve_generation_provider(%{provider: provider} = credential, id)
       when is_binary(provider) do
    case provider_atom(provider) do
      {:ok, provider} -> generation_adapter(provider, catalog_model(provider, id), credential)
      {:error, :provider_not_found} -> openai_if_custom_endpoint(credential)
    end
  end

  defp resolve_generation_provider(_credential, _id), do: {:error, :invalid_provider}

  defp provider_atom(provider) do
    provider = String.downcase(provider)

    case LLMDB.Spec.parse_provider(provider) do
      {:ok, _} = found -> found
      {:error, _} -> {:ok, String.to_existing_atom(provider)}
    end
  rescue
    ArgumentError -> {:error, :provider_not_found}
  end

  defp catalog_model(provider, id) when is_binary(id) do
    case LLMDB.model(provider, id) do
      {:ok, model} -> model
      {:error, _} -> nil
    end
  end

  defp catalog_model(_provider, _id), do: nil

  defp generation_adapter(_provider, %{capabilities: %{chat: false}}, _credential),
    do: {:error, :model_not_supported}

  defp generation_adapter(provider, model, credential) do
    case ReqLLM.provider(provider) do
      {:ok, _module} -> {:ok, provider}
      {:error, _} -> generation_compatibility(model, provider, credential)
    end
  end

  defp generation_compatibility(
         %{catalog_only: true, capabilities: %{chat: true}},
         _provider,
         credential
       ) do
    case openai_if_custom_endpoint(credential) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :provider_not_supported}
    end
  end

  defp generation_compatibility(_model, provider, credential) do
    case LLMDB.provider(provider) do
      {:ok, _} -> {:error, :provider_not_supported}
      {:error, _} -> openai_if_custom_endpoint(credential)
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
    implementation = Registry.fetch(cfg.provider)
    implementation.default_advanced_options(cfg)
  end

  def default_advanced_options(%{provider: provider} = cfg) do
    implementation = Registry.fetch(provider)
    implementation.default_advanced_options(cfg)
  end

  def default_advanced_options(_cfg), do: %{}

  @doc """
  Builds ReqLLM keyword opts for a configured agent.

  Dedicated sampling fields take precedence over overlapping `advanced_options`
  keys. Authentication and endpoint options come from the resolved credential.
  """
  @spec llm_opts(ConfiguredAgent.t()) :: keyword()
  def llm_opts(%ConfiguredAgent{} = configured_agent) do
    credential = resolve_credential(configured_agent)
    context = provider_context(credential, nil)
    implementation = Registry.fetch(context.provider)
    implementation.put_credential_opts(advanced_options_as_keyword(configured_agent), context)
  end

  @doc """
  Builds ReqLLM options from one already-resolved Connect authentication result.

  This lifecycle entrypoint translates authentication only. Connect remains
  responsible for selecting the effective Person or org grant.
  """
  @spec llm_opts(ConfiguredAgent.t(), ResolvedCredential.t() | nil) ::
          {:ok, keyword()} | {:error, {:unsupported_ai_authentication, String.t()}}
  def llm_opts(%ConfiguredAgent{} = configured_agent, nil) do
    {:ok, advanced_options_as_keyword(configured_agent)}
  end

  def llm_opts(%ConfiguredAgent{} = configured_agent, %ResolvedCredential{} = resolved) do
    credential = resolve_credential(configured_agent)
    base_opts = advanced_options_as_keyword(configured_agent)
    context = provider_context(credential, resolved)
    implementation = Registry.fetch(context.provider)

    case resolved.auth_kind do
      kind when kind in ["api_key", "oauth2", "none"] ->
        {:ok, implementation.put_credential_opts(base_opts, context)}

      unsupported ->
        {:error, {:unsupported_ai_authentication, unsupported}}
    end
  end

  @doc """
  Builds ReqLLM keyword opts from one AI provider credential.
  """
  @spec credential_opts(Zaq.System.AIProviderCredential.t() | map() | nil) :: keyword()
  def credential_opts(credential) do
    context = provider_context(credential, nil)
    implementation = Registry.fetch(context.provider)
    implementation.put_credential_opts([], context)
  end

  defp credential_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp credential_metadata(_), do: %{}

  defp model_context(credential, runtime_provider) do
    %{
      provider: credential_value(credential, :provider) || runtime_provider,
      runtime_provider: runtime_provider,
      endpoint: credential_value(credential, :endpoint),
      metadata: credential_metadata(credential),
      auth_kind: nil,
      authentication: %{},
      runtime_identity: %{}
    }
  end

  defp provider_context(credential, resolved, runtime_provider \\ nil) do
    provider = credential_value(credential, :provider)
    metadata = credential_metadata(credential)

    %{
      provider: provider || runtime_provider,
      runtime_provider: runtime_provider || reqllm_provider(provider),
      endpoint: credential_value(credential, :endpoint),
      metadata: metadata,
      auth_kind: auth_kind(credential, resolved, metadata),
      authentication: authentication(credential, resolved, metadata),
      runtime_identity: runtime_identity(credential, resolved, metadata)
    }
  end

  defp auth_kind(_credential, %ResolvedCredential{auth_kind: kind}, _metadata), do: kind

  defp auth_kind(credential, nil, metadata) do
    MapUtils.metadata_value(metadata, "auth_kind") ||
      if(present?(credential_value(credential, :access_token)), do: "oauth2", else: "api_key")
  end

  defp authentication(
         _credential,
         %ResolvedCredential{authentication: authentication},
         _metadata
       ),
       do: authentication

  defp authentication(credential, nil, metadata) do
    secret = legacy_secret(credential)

    case auth_kind(credential, nil, metadata) do
      "oauth2" -> maybe_authentication(:access_token, secret)
      "none" -> %{}
      _ -> maybe_authentication(:api_key, secret)
    end
  end

  defp runtime_identity(_credential, %ResolvedCredential{metadata: metadata}, _configuration),
    do: metadata

  defp runtime_identity(credential, nil, metadata),
    do: credential_value(credential, :runtime_identity) || metadata

  defp legacy_secret(%System.AIProviderCredential{} = credential),
    do: System.resolve_ai_provider_api_key(credential)

  defp legacy_secret(credential),
    do: credential_value(credential, :access_token) || credential_value(credential, :api_key)

  defp maybe_authentication(_key, value) when value in [nil, ""], do: %{}
  defp maybe_authentication(key, value), do: %{key => value}

  defp present?(value), do: is_binary(value) and value != ""

  defp resolve_credential(%ConfiguredAgent{
         credential: %System.AIProviderCredential{} = credential
       }),
       do: credential

  defp resolve_credential(%ConfiguredAgent{credential: credential})
       when is_map(credential) and not is_struct(credential),
       do: credential

  defp resolve_credential(%ConfiguredAgent{credential_id: id}) when is_integer(id),
    do: Zaq.System.get_ai_provider_credential(id)

  defp resolve_credential(_), do: nil

  defp credential_value(credential, key) when is_map(credential),
    do: Map.get(credential, key, Map.get(credential, Atom.to_string(key)))

  defp credential_value(_, _), do: nil

  defp advanced_options_as_keyword(%ConfiguredAgent{} = agent) do
    (agent.advanced_options || %{})
    |> Enum.reduce([], fn {key, value}, acc ->
      case normalize_option_key(key) do
        nil -> acc
        atom_key -> [{atom_key, value} | acc]
      end
    end)
    |> Enum.reverse()
    |> Keyword.merge(temperature: agent.temperature, top_p: agent.top_p)
  end

  defp normalize_option_key(key) when is_atom(key), do: key

  defp normalize_option_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError ->
      Logger.warning("Ignoring unsupported advanced option key: #{inspect(key)}")
      nil
  end

  defp normalize_option_key(_), do: nil
end
