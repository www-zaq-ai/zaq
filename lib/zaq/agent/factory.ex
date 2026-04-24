defmodule Zaq.Agent.Factory do
  @moduledoc """
  Standard Jido agent used for BO-managed configured agents.

  All configured agents execute through this module. Per-agent specifics are
  applied at runtime (server model/runtime state and request tool/llm options).
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

  # Providers natively supported by ReqLLM. Everything else is treated as OpenAI-compatible.
  @reqllm_providers ~w(openai anthropic google xai mistral)

  # Providers that manage their own API URLs inside ReqLLM — never override with base_url.
  @fixed_url_providers ~w(anthropic google xai mistral)

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

    if cfg.supports_logprobs do
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
         llm_opts: llm_opts(configured_agent),
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

  defp reqllm_provider(p) when p in @reqllm_providers, do: String.to_atom(p)
  defp reqllm_provider(_), do: :openai

  defp maybe_put_base_url(spec, %{provider: p}) when p in @fixed_url_providers, do: spec

  defp maybe_put_base_url(spec, %{endpoint: url}) when is_binary(url) and url != "",
    do: Map.put(spec, :base_url, url)

  defp maybe_put_base_url(spec, _), do: spec
end
