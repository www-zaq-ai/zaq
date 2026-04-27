defmodule Zaq.Agent.Factory do
  @moduledoc """
  Jido AI agent implementation shared by all configured agents.

  One Factory server is spawned per agent scope. Provides `ask_with_config/4`
  to send a query with per-agent tool and LLM opts resolved at call time.
  The built-in answering agent configuration lives in `Zaq.Agent.Answering`.
  """

  use Jido.AI.Agent,
    name: "agent_factory",
    description: "Runtime-configured standard ZAQ agent",
    request_policy: :reject,
    tools: [],
    plugins: []

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Registry
  alias Zaq.System
  require Logger

  # Providers that manage their own base URL inside ReqLLM — never override with a custom base_url.
  # This list cannot be derived automatically from the llm_db catalog: the catalog's `base_url`
  # field marks a provider's default endpoint, not whether it is user-overridable. For example,
  # both `openai` (overridable) and `anthropic` (not overridable) have `base_url` in the catalog.
  @fixed_url_providers ~w(anthropic google xai mistral)a

  def strategy_opts do
    super()
    |> Keyword.delete(:model)
  end

  @doc """
  Returns a ReqLLM inline model spec map from the system LLM config.

  Uses `cfg.endpoint` directly as `base_url` — do NOT append `cfg.path`
  (ReqLLM appends the provider path itself). Anthropic uses its own default
  API URL so no `base_url` is set for that provider.
  """
  def build_model_spec do
    cfg = System.get_llm_config()
    provider = reqllm_provider(cfg.provider)

    %{provider: provider, id: cfg.model}
    |> maybe_put_base_url(cfg)
  end

  @doc """
  Returns a ReqLLM inline model spec map for a configured agent.

  Resolves the provider via LLMDB and the agent's credential. Falls back to
  `:openai` when the provider is unknown to LLMDB but the credential carries a
  custom endpoint — indicating an intentional OpenAI-compatible deployment.
  """
  @spec build_model_spec(ConfiguredAgent.t()) :: {:ok, map()} | {:error, atom()}
  def build_model_spec(%ConfiguredAgent{} = configured_agent) do
    credential =
      configured_agent.credential ||
        System.get_ai_provider_credential(configured_agent.credential_id)

    with {:ok, runtime_provider} <- resolve_configured_provider(configured_agent, credential) do
      spec = %{provider: runtime_provider, id: configured_agent.model}
      {:ok, maybe_put_base_url(spec, runtime_provider, credential)}
    end
  end

  @doc "Sampling opts for ReqLLM generation calls. Includes api_key and logprobs when configured."
  def generation_opts do
    cfg = System.get_llm_config()
    opts = [temperature: cfg.temperature, top_p: cfg.top_p]

    opts =
      if is_binary(cfg.api_key) and cfg.api_key != "" do
        Keyword.put(opts, :api_key, cfg.api_key)
      else
        opts
      end

    if cfg.supports_logprobs and reqllm_provider(cfg.provider) == :openai do
      Keyword.put(opts, :provider_options, openai_logprobs: true)
    else
      opts
    end
  end

  @spec runtime_config(ConfiguredAgent.t()) :: {:ok, map()} | {:error, term()}
  def runtime_config(%ConfiguredAgent{} = configured_agent) do
    with {:ok, tools} <- Registry.resolve_modules(configured_agent.enabled_tool_keys || []) do
      {:ok,
       %{
         tools: tools,
         # Merges system LLM sampling opts (temperature, top_p) as defaults until per-agent
         # advanced options are wired into ConfiguredAgent and surfaced in the BO UI.
         llm_opts: Keyword.merge(generation_opts(), llm_opts(configured_agent)),
         system_prompt: configured_agent.job || ""
       }}
    end
  end

  @spec ask_with_config(GenServer.server(), String.t(), ConfiguredAgent.t(), keyword()) ::
          {:ok, Jido.AI.Request.Handle.t()} | {:error, term()}
  def ask_with_config(server, query, %ConfiguredAgent{} = configured_agent, opts \\ [])
      when is_binary(query) do
    with {:ok, config} <- server_runtime_config(server, configured_agent),
         :ok <- ensure_system_prompt(server, Map.get(config, :system_prompt, "")) do
      ask_opts =
        opts
        |> Keyword.put(:tools, Map.get(config, :tools, []))
        |> Keyword.put(:llm_opts, Map.get(config, :llm_opts, []))
        |> Keyword.put_new(:timeout, 30_000)

      ask(server, query, ask_opts)
    end
  end

  defp server_runtime_config(server, configured_agent) do
    case Jido.AgentServer.status(server) do
      {:ok, %{raw_state: %{runtime_config: %{} = config}}} ->
        {:ok, config}

      _ ->
        runtime_config(configured_agent)
    end
  end

  defp ensure_system_prompt(_server, prompt) when prompt in [nil, ""], do: :ok

  defp ensure_system_prompt(server, prompt) when is_binary(prompt) do
    case current_system_prompt(server) do
      ^prompt ->
        :ok

      _other ->
        do_set_system_prompt(server, prompt, 4)
    end
  end

  defp current_system_prompt(server) do
    case Jido.AgentServer.status(server) do
      {:ok, %{raw_state: %{__strategy__: %{config: %{system_prompt: prompt}}}}}
      when is_binary(prompt) ->
        prompt

      _ ->
        nil
    end
  end

  defp do_set_system_prompt(_server, _prompt, 0), do: {:error, :system_prompt_config_failed}

  defp do_set_system_prompt(server, prompt, attempts_left) do
    case Jido.AI.set_system_prompt(server, prompt, timeout: 5_000) do
      {:ok, _agent} ->
        :ok

      {:error, _reason} ->
        Process.sleep(20)
        do_set_system_prompt(server, prompt, attempts_left - 1)
    end
  end

  defp llm_opts(%ConfiguredAgent{} = configured_agent) do
    credential = credential(configured_agent)

    configured_agent
    |> advanced_options_as_keyword()
    |> maybe_put(:api_key, credential && credential.api_key)
    |> maybe_put(:base_url, credential && credential.endpoint)
  end

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

  defp credential(%ConfiguredAgent{credential: credential}) when not is_nil(credential),
    do: credential

  defp credential(%ConfiguredAgent{credential_id: credential_id})
       when is_integer(credential_id) do
    System.get_ai_provider_credential(credential_id)
  end

  defp credential(_), do: nil

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
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

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

  defp maybe_put_base_url(spec, %{provider: p} = cfg) do
    if fixed_url_provider?(reqllm_provider(p)) do
      spec
    else
      case cfg do
        %{endpoint: url} when is_binary(url) and url != "" -> Map.put(spec, :base_url, url)
        _ -> spec
      end
    end
  end

  defp maybe_put_base_url(spec, _), do: spec

  defp maybe_put_base_url(spec, provider, credential) when is_atom(provider) do
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
