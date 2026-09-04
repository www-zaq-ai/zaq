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
  - Cold-start memory hydration via `build_initial_context/3`, delegating to
    `Zaq.Agent.HistoryLoader` using scope information encoded in server IDs.
  - Safe request dispatch via `ask_with_config/4`, including server-state
    runtime-config fallback and best-effort system prompt synchronization before
    each ask.
  - Streamed request dispatch; callers consume runtime events from `ask_stream/3`
    for status updates, trace collection, and measurements.

  Typical flow:

  1. `Zaq.Agent.ServerManager` calls `runtime_config/1` and
     `build_initial_context/3` when spawning a server.
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
    request_transformer: Zaq.Agent.ContextWindow.RequestTransformer,
    plugins: [
      {Jido.MCP.Plugins.MCP, %{allowed_endpoints: :all}},
      Jido.MCP.JidoAI.Plugins.MCPAI
    ],
    tools: []

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Skill.AgentIntegration

  alias Zaq.Agent.{
    ConfiguredAgent,
    HistoryLoader,
    MediaResultTransformer,
    OpaqueAliases,
    ProviderSpec,
    Skills
  }

  alias Zaq.Agent.Tools.Registry
  alias Zaq.System

  def strategy_opts do
    super()
    |> Keyword.delete(:model)
  end

  # Jido.AI.Agent discovers these optional interception callbacks by name.
  def before_tool_call(tool_call, context) do
    OpaqueAliases.expand_tool_call(tool_call, context)
  end

  # Jido.AI.Agent discovers these optional interception callbacks by name.
  def after_tool_call(tool_call, result, context) do
    case OpaqueAliases.alias_tool_result(tool_call, result, context) do
      {:ok, result} -> MediaResultTransformer.project_tool_result(tool_call, result, context)
      {:error, reason} -> {:error, reason}
    end
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

  Resolves tool modules from `enabled_tool_keys` unioned with attached skill tools
  (`Zaq.Agent.Skills.provisioned_tool_keys/2`) via `Tools.Registry`, merges system-level
  LLM sampling opts with any per-agent overrides from `ProviderSpec`, and returns the
  agent's `job` field plus rendered skill instructions as the system prompt.

  Returns `{:ok, %{tools: [...], llm_opts: [...], system_prompt: binary()}}` or
  `{:error, reason}` if tool resolution fails.

  This is the fallback path used by `ask_with_config/4` when the live server has no cached
  `runtime_config` in its state (e.g. first call after a cold start).
  """
  @spec runtime_config(ConfiguredAgent.t()) :: {:ok, map()} | {:error, term()}
  def runtime_config(%ConfiguredAgent{} = configured_agent) do
    skills = Skills.enabled_for_agent(configured_agent)

    with {:ok, skill_integration} <- skill_runtime_integration(skills),
         {:ok, tools} <-
           Registry.resolve_modules(Skills.provisioned_tool_keys(configured_agent, skills)) do
      {:ok,
       %{
         tools: Enum.uniq(tools ++ skill_integration.tools),
         # Merges system LLM sampling opts (temperature, top_p) as defaults until per-agent
         # advanced options are wired into ConfiguredAgent and surfaced in the BO UI.
         llm_opts: Keyword.merge(generation_opts(), ProviderSpec.llm_opts(configured_agent)),
         system_prompt: runtime_system_prompt(configured_agent, skills, skill_integration),
         tool_context: skill_integration.tool_context,
         context_window: context_window_config(configured_agent)
       }}
    end
  end

  defp skill_runtime_integration([]), do: {:ok, %{tools: [], index: "", tool_context: %{}}}

  defp skill_runtime_integration(skills) do
    AgentIntegration.prepare(
      specs: Skills.to_specs(skills),
      resource_provider: {Zaq.Agent.Skill.ResourceProvider, :handle}
    )
  end

  defp runtime_system_prompt(configured_agent, _skills, %{index: index}) when is_binary(index) do
    job = configured_agent.job || ""

    case index do
      "" -> job
      index when job == "" -> index
      index -> job <> "\n\n" <> index
    end
  end

  @doc """
  Builds the initial `Jido.AI.Context` for a cold-started agent by loading recent history.

  Routes to conversation history when `incoming.metadata.conversation_id` is present,
  otherwise loads by `person_id` + normalized provider. Returns an empty context when
  `incoming` is `nil` or the relevant identifiers are absent.

  When `context` is a pre-built `Jido.AI.Context` (e.g. `RunAgent` supplies the
  step's turns via `opts[:context]`), it is used **as-is** and no history is loaded
  — the caller has already assembled the agent's entire starting context. This is
  exactly right for a per-step workflow scope, which would load no DB history anyway.
  Otherwise (`nil`), history is loaded from the scope encoded in `server_id`.
  """
  @spec build_initial_context(ConfiguredAgent.t(), String.t(), AIContext.t() | nil) ::
          AIContext.t()
  def build_initial_context(configured_agent, server_id, context \\ nil)

  def build_initial_context(%ConfiguredAgent{}, _server_id, %AIContext{} = context), do: context

  def build_initial_context(%ConfiguredAgent{}, server_id, _context) do
    spawn_opts = spawn_opts_from_server_id(server_id)

    HistoryLoader.load_context(spawn_opts, opaque_alias_scope: server_id)
  end

  def spawn_opts_from_server_id(server_id) when is_binary(server_id) do
    case String.split(server_id, ":") |> Enum.reverse() do
      [id, "conv", encoded_provider, "scope" | [_agent | _]] when id != "" ->
        case decode_scope_provider(encoded_provider) do
          {:ok, provider} -> %{conversation_id: id, person_id: nil, channel_type: provider}
          :error -> %{}
        end

      [id, "person", encoded_provider, "scope" | [_agent | _]] when id != "" ->
        case decode_scope_provider(encoded_provider) do
          {:ok, provider} -> %{conversation_id: nil, person_id: id, channel_type: provider}
          :error -> %{}
        end

      # Per-run scope `workflow:run:<id>` (derived by Executor.derive_scope/2 from
      # the incoming's run_id) has no prior conversation/person to load — a
      # workflow-run agent starts fresh. Matched explicitly so this is
      # intentional, not a fall-through.
      [_id, "run", "workflow" | [_agent | _]] ->
        %{}

      _ ->
        %{}
    end
  end

  def spawn_opts_from_server_id(_server_id), do: nil

  defp decode_scope_provider(encoded_provider) when is_binary(encoded_provider) do
    if encoded_provider != "" and valid_percent_encoding?(encoded_provider) do
      decoded = URI.decode(encoded_provider)

      if decoded == "", do: :error, else: {:ok, decoded}
    else
      :error
    end
  end

  defp valid_percent_encoding?(value) do
    not Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, value)
  end

  @doc """
  Sends a query to a running agent server with the configured agent's LLM and tool settings.

  Reads `runtime_config` from the server's live state when available, falling back to
  `runtime_config/1` on a cold server. Ensures the system prompt is set before dispatching,
  retrying up to 4 times with a 20 ms backoff if `set_system_prompt` fails.

  Returns `{:ok, %{request: request_handle, events: events}}` for callers to reduce
  through `Zaq.Agent.StreamEvents.consume/3`, or `{:error, reason}`.

  ## Options

  - `:timeout` — ask timeout in milliseconds; defaults to `300_000`
  - `:context` — map passed into retrieval for permission scoping (`:person_id`, `:team_ids`)
  - Any other opts are forwarded to the underlying `Jido.AI.Agent` ask call
  """
  @spec ask_with_config(GenServer.server(), String.t(), ConfiguredAgent.t(), keyword()) ::
          {:ok, %{request: term(), events: Enumerable.t()}} | {:error, term()}
  def ask_with_config(server, query, %ConfiguredAgent{} = configured_agent, opts \\ [])
      when is_binary(query) do
    skills = Skills.enabled_for_agent(configured_agent)

    with {:ok, config} <- server_runtime_config(server, configured_agent),
         {:ok, skill_integration} <- skill_runtime_integration(skills),
         :ok <- ensure_native_skill_tools_registered(server, skill_integration),
         prompt <- runtime_system_prompt(configured_agent, skills, skill_integration),
         :ok <- ensure_system_prompt(server, prompt) do
      ask_opts =
        opts
        |> Keyword.put(:llm_opts, Map.get(config, :llm_opts, []))
        |> Keyword.put(:max_iterations, configured_agent.max_iterations || 10)
        |> Keyword.put_new(:timeout, 300_000)
        |> put_runtime_tool_context(skill_integration)
        |> put_context_window(config)
        |> maybe_put_tool_timeout(config)

      ask_stream(server, query, ask_opts)
    end
  end

  # Raise the run's per-tool react timeout when an enabled tool needs more than
  # jido_ai's 15s default. Factory holds no per-tool knowledge — each tool
  # declares its own minimum (see `tool_timeout_ms/1`).
  defp maybe_put_tool_timeout(opts, config) do
    case config |> Map.get(:tools, []) |> tool_timeout_ms() do
      nil -> opts
      ms -> Keyword.put_new(opts, :tool_timeout_ms, ms)
    end
  end

  defp context_window_config(%ConfiguredAgent{} = configured_agent) do
    %{
      max_context_tokens: configured_agent.model_max_context_tokens || 5_000,
      tokens_per_character: 0.5,
      safety_margin: 0.05
    }
  end

  defp put_context_window(opts, config) do
    context =
      opts
      |> Keyword.get(:tool_context, %{})
      |> case do
        %{} = context -> context
        _ -> %{}
      end
      |> Map.put(:context_window, Map.get(config, :context_window, %{}))

    Keyword.put(opts, :tool_context, context)
  end

  defp put_runtime_tool_context(opts, skill_integration) do
    runtime_context = Map.get(skill_integration, :tool_context, %{})

    context =
      opts
      |> Keyword.get(:tool_context, %{})
      |> case do
        %{} = context -> Map.merge(context, runtime_context)
        _ -> runtime_context
      end

    Keyword.put(opts, :tool_context, context)
  end

  @doc """
  Per-tool react execution timeout (ms) required by `tools`, or `nil` to use
  jido_ai's default (15s).

  A tool that needs longer than the default (e.g. browser automation, whose cold
  commands can exceed 15s and would otherwise abort the run) declares the minimum
  it requires via an optional `tool_timeout_ms/0` on its module. This maps
  generically over the enabled tool modules and takes the maximum — Factory holds
  no per-tool knowledge; tools that declare nothing keep the responsive default.
  """
  @spec tool_timeout_ms([module()]) :: pos_integer() | nil
  def tool_timeout_ms(tools) when is_list(tools) do
    tools
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :tool_timeout_ms, 0)))
    |> Enum.map(& &1.tool_timeout_ms())
    |> case do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  @doc """
  Awaits a request handle or the stream envelope returned by `ask_with_config/4`.
  """
  @spec await(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def await(%{request: request}, opts), do: await(request, opts)
  def await(request, opts), do: super(request, opts)

  defp server_runtime_config(server, configured_agent) do
    case Jido.AgentServer.status(server) do
      {:ok, %{raw_state: %{runtime_config: %{} = config}}} -> {:ok, config}
      _ -> runtime_config(configured_agent)
    end
  end

  defp ensure_native_skill_tools_registered(_server, %{tools: tools}) when tools in [nil, []],
    do: :ok

  defp ensure_native_skill_tools_registered(server, %{tools: tools}) do
    case Jido.AI.list_tools(server) do
      {:ok, registered} when is_list(registered) ->
        missing = tools -- registered

        if missing == [] do
          :ok
        else
          {:error, {:runtime_sync_required, Enum.map(missing, & &1.name())}}
        end

      {:error, reason} ->
        {:error, {:runtime_sync_check_failed, reason}}
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
