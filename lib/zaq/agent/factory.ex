defmodule Zaq.Agent.Factory do
  @moduledoc """
  Runtime agent implementation used by every configured ZAQ agent.

  This module is the execution bridge between `Zaq.Agent.Executor` and the
  underlying `Jido.AI.Agent` process managed by `Zaq.Agent.ServerManager`.

  Key concerns handled here:

  - Runtime config assembly per configured agent via `runtime_config/1`:
    resolves enabled tool modules (`Zaq.Agent.Tools.Registry`), builds effective
    LLM options (system defaults from `Zaq.System` merged with per-agent
    overrides from `Zaq.Agent.ProviderSpec`), and derives the system prompt.
  - Cold-start memory hydration via `build_initial_context/2`, delegating to
    `Zaq.Agent.HistoryLoader` using scope information encoded in server IDs.
  - Safe request dispatch via `ask_with_config/4`, including server-state
    runtime-config fallback and best-effort system prompt synchronization before
    each ask.
  - Request-scoped runtime context propagation for status updates and tool trace
    collection, using process-local keys consumed by surrounding pipeline code.

  Typical flow:

  1. `Zaq.Agent.ServerManager` calls `runtime_config/1` and
     `build_initial_context/2` when spawning a server.
  2. `Zaq.Agent.Executor` calls `ask_with_config/4` to run an incoming question.
  3. The request runs through Jido with the resolved tools, model opts, and
     synchronized prompt.

  The built-in default answering configuration is provided by
  `Zaq.Agent.Answering`; this module executes that config exactly like any other
  configured agent.
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
  @spec build_initial_context(ConfiguredAgent.t(), String.t()) :: AIContext.t()
  def build_initial_context(%ConfiguredAgent{} = configured_agent, server_id) do
    spawn_opts = spawn_opts_from_server_id(server_id)

    HistoryLoader.load_context(
      spawn_opts,
      max_tokens: configured_agent.memory_context_max_size || 5_000
    )
  end

  def spawn_opts_from_server_id(server_id) when is_binary(server_id) do
    case String.split(server_id, ":") do
      [_agent, provider, "conv", id] when provider != "" and id != "" ->
        %{conversation_id: id, person_id: nil, channel_type: provider}

      [_agent, provider, "person", id] when provider != "" and id != "" ->
        %{conversation_id: nil, person_id: id, channel_type: provider}

      _ ->
        %{}
    end
  end

  def spawn_opts_from_server_id(_server_id), do: nil

  @doc """
  Sends a query to a running agent server with the configured agent's LLM and tool settings.

  Reads `runtime_config` from the server's live state when available, falling back to
  `runtime_config/1` on a cold server. Ensures the system prompt is set before dispatching,
  retrying up to 4 times with a 20 ms backoff if `set_system_prompt` fails.

  Returns `{:ok, request_handle}` that callers pass to `await/2`, or `{:error, reason}`.

  ## Options

  - `:timeout` — ask timeout in milliseconds; defaults to `300_000`
  - `:context` — map passed into retrieval for permission scoping (`:person_id`, `:team_ids`)
  - Any other opts are forwarded to the underlying `Jido.AI.Agent` ask call
  """
  @spec ask_with_config(GenServer.server(), String.t(), ConfiguredAgent.t(), keyword()) ::
          {:ok, Jido.AI.Request.Handle.t()} | {:error, term()}
  def ask_with_config(server, query, %ConfiguredAgent{} = configured_agent, opts \\ [])
      when is_binary(query) do
    with {:ok, config} <- server_runtime_config(server, configured_agent),
         :ok <- ensure_system_prompt(server, configured_agent.job || "") do
      llm_opts =
        config
        |> Map.get(:llm_opts, [])
        |> maybe_put_tool_choice(Map.get(config, :tools, []))

      ask_opts =
        opts
        |> Keyword.put(:llm_opts, Map.get(config, :llm_opts, []))
        |> Keyword.put_new(:timeout, 300_000)

      ask(server, query, ask_opts)
    end
  end

  @impl true
  def on_before_cmd(agent, {:ai_react_start, params} = action) do
    maybe_put_status_context(params)
    super(agent, action)
  end

  def on_before_cmd(agent, action), do: super(agent, action)

  @impl true
  def on_after_cmd(agent, {:ai_react_cancel, _params} = action, directives) do
    Process.delete(:zaq_status_context)
    Process.delete(:zaq_tool_trace_context)
    super(agent, action, directives)
  end

  def on_after_cmd(agent, {:ai_react_request_error, _params} = action, directives) do
    Process.delete(:zaq_status_context)
    Process.delete(:zaq_tool_trace_context)
    super(agent, action, directives)
  end

  def on_after_cmd(agent, {:ai_react_finish, _params} = action, directives) do
    Process.delete(:zaq_status_context)
    Process.delete(:zaq_tool_trace_context)
    super(agent, action, directives)
  end

  def on_after_cmd(agent, action, directives), do: super(agent, action, directives)

  defp maybe_put_status_context(params) when is_map(params) do
    refs = Map.get(params, :extra_refs, %{})

    case Map.get(refs, :zaq_status_context) do
      %{session_id: _session_id, request_id: request_id} = ctx
      when is_binary(request_id) and request_id != "" ->
        Process.put(:zaq_status_context, ctx)

      _ ->
        :ok
    end

    maybe_put_tool_trace_context(refs)
  end

  defp maybe_put_status_context(_), do: :ok

  defp maybe_put_tool_trace_context(refs) when is_map(refs) do
    case Map.get(refs, :zaq_tool_trace_context) do
      %{request_id: request_id, collector_pid: collector_pid}
      when is_binary(request_id) and request_id != "" and is_pid(collector_pid) ->
        Process.put(:zaq_tool_trace_context, %{
          request_id: request_id,
          collector_pid: collector_pid
        })

      _ ->
        :ok
    end
  end

  defp maybe_put_tool_trace_context(_), do: :ok

  defp maybe_put_tool_choice(llm_opts, tools) when tools != [] do
    Keyword.put_new(llm_opts, :tool_choice, :required)
  end

  defp maybe_put_tool_choice(llm_opts, _tools), do: llm_opts

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
