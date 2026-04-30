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
    plugins: [
      {Jido.MCP.Plugins.MCP, %{allowed_endpoints: :all}},
      Jido.MCP.JidoAI.Plugins.MCPAI
    ],
    tools: []

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.{ConfiguredAgent, HistoryLoader, ProviderSpec}
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.System

  def strategy_opts do
    super()
    |> Keyword.delete(:model)
  end

  # Replace with per-agent advanced LLM opts so each ConfiguredAgent carries its own
  # temperature/top_p/logprobs config instead of falling back to the global system LLM config.
  @doc """
  Returns LLM sampling opts (temperature, top_p, etc.) from the system LLM config.

  Called by `runtime_config/1` as the baseline for every agent until per-agent advanced
  options are surfaced in the BO UI. Reads live from `Zaq.System.get_llm_config/0` on
  each call — no caching.
  """
  def generation_opts, do: System.get_llm_config() |> ProviderSpec.generation_opts()

  @doc """
  Resolves the runtime configuration map for a configured agent.

  Resolves tool modules from `enabled_tool_keys` via `Tools.Registry`, merges system-level
  LLM sampling opts with any per-agent overrides from `ProviderSpec`, and returns the
  agent's `job` field as the system prompt.

  Returns `{:ok, %{tools: [...], llm_opts: [...], system_prompt: binary()}}` or
  `{:error, reason}` if tool resolution fails.

  This is the fallback path used by `ask_with_config/4` when the live server has no cached
  `runtime_config` in its state (e.g. first call after a cold start).
  """
  @spec runtime_config(ConfiguredAgent.t()) :: {:ok, map()} | {:error, term()}
  def runtime_config(%ConfiguredAgent{} = configured_agent) do
    with {:ok, tools} <- Registry.resolve_modules(configured_agent.enabled_tool_keys || []) do
      {:ok,
       %{
         tools: tools,
         # Merges system LLM sampling opts (temperature, top_p) as defaults until per-agent
         # advanced options are wired into ConfiguredAgent and surfaced in the BO UI.
         llm_opts: Keyword.merge(generation_opts(), ProviderSpec.llm_opts(configured_agent)),
         system_prompt: configured_agent.job || ""
       }}
    end
  end

  @doc """
  Builds the initial `Jido.AI.Context` for a cold-started agent by loading recent history.

  Routes to conversation history when `incoming.metadata.conversation_id` is present,
  otherwise loads by `person_id` + normalized provider. Returns an empty context when
  `incoming` is `nil` or the relevant identifiers are absent.
  """
  @spec build_initial_context(Incoming.t() | nil, ConfiguredAgent.t()) :: AIContext.t()
  def build_initial_context(nil, _configured_agent), do: AIContext.new()

  def build_initial_context(%Incoming{} = incoming, %ConfiguredAgent{} = configured_agent) do
    HistoryLoader.load_context(
      %{
        conversation_id: incoming.metadata[:conversation_id],
        person_id: incoming.person_id,
        channel_type: normalize_provider(incoming.provider)
      },
      max_tokens: configured_agent.memory_context_max_size || 5_000
    )
  end

  @doc false
  def normalize_provider(:web), do: "bo"

  def normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.replace(":", "_")

  def normalize_provider(provider) when is_binary(provider),
    do: String.replace(provider, ":", "_")

  @doc """
  Sends a query to a running agent server with the configured agent's LLM and tool settings.

  Reads `runtime_config` from the server's live state when available, falling back to
  `runtime_config/1` on a cold server. Ensures the system prompt is set before dispatching,
  retrying up to 4 times with a 20 ms backoff if `set_system_prompt` fails.

  Returns `{:ok, request_handle}` that callers pass to `await/2`, or `{:error, reason}`.

  ## Options

  - `:timeout` — ask timeout in milliseconds; defaults to `30_000`
  - `:context` — map passed into retrieval for permission scoping (`:person_id`, `:team_ids`)
  - Any other opts are forwarded to the underlying `Jido.AI.Agent` ask call
  """
  @spec ask_with_config(GenServer.server(), String.t(), ConfiguredAgent.t(), keyword()) ::
          {:ok, Jido.AI.Request.Handle.t()} | {:error, term()}
  def ask_with_config(server, query, %ConfiguredAgent{} = configured_agent, opts \\ [])
      when is_binary(query) do
    with {:ok, config} <- server_runtime_config(server, configured_agent),
         :ok <- ensure_system_prompt(server, Map.get(config, :system_prompt, "")) do
      ask_opts =
        opts
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
end
