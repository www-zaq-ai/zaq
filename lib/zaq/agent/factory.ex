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
    plugins: [
      {Jido.MCP.Plugins.MCP, %{allowed_endpoints: :all}},
      Jido.MCP.JidoAI.Plugins.MCPAI
    ],
    tools: []

  alias Jido.Agent.Strategy.State, as: StrategyState
  alias Jido.AI.Context, as: AIContext

  alias Zaq.Agent.{
    ConfiguredAgent,
    ContextWindow,
    HistoryLoader,
    MaterializationAliases,
    MediaResultTransformer,
    ProviderSpec,
    Skills
  }

  alias Zaq.Agent.Tools.Registry
  alias Zaq.System

  @default_memory_context_max_size 5_000

  # `ContextWindow` bounds every outgoing turn against the agent's
  # `memory_context_max_size`. It is registered as the ReAct request transformer
  # (rather than applied at the call site) because that is the only hook that
  # runs per LLM turn — a single run whose tool results balloon across iterations
  # would otherwise blow the budget without any ask-level check ever firing.
  def strategy_opts do
    super()
    |> Keyword.delete(:model)
    |> Keyword.put(:request_transformer, ContextWindow)
  end

  # `memory_context_max_size` is a maximum, so it has to hold at rest and not only
  # on the wire. This trims the committed context the moment a run settles, which
  # is the only point where the thread is both complete and idle — trimming before
  # an ask instead would always leave the turn that ask appends untrimmed.
  #
  # It writes the context rather than sending an `ai.react.context.modify` signal
  # because that signal cannot express "trim whatever is there now": it carries a
  # snapshot, and `ReAct.Strategy` defers it whenever a run is in flight, so an op
  # raised here would be applied *after* the next run committed and would replace
  # that newer context with this older one. Its `base_seq` field, which would have
  # guarded exactly that, is normalised and then never read. Writing in-process is
  # the only form that cannot go stale — and it also keeps
  # `preserve_durable_entries/3` out of the path, which is what re-ordered durable
  # tool results ahead of their assistant stub.
  @impl true
  def on_after_cmd(agent, action, directives) do
    {:ok, agent, directives} = super(agent, action, directives)
    {:ok, trim_settled_context(agent), directives}
  end

  defp trim_settled_context(agent) do
    strategy = StrategyState.get(agent)

    with false <- active_run?(strategy),
         %AIContext{} = context <- Map.get(strategy, :context),
         budget when is_integer(budget) and budget > 0 <-
           get_in(agent.state, [:runtime_config, :memory_context_max_size]) do
      # No run is in flight, so anchor on the newest group rather than the last
      # `:user` entry — same reasoning as the cold path.
      fitted = ContextWindow.fit(context, max_tokens: budget, anchor: :newest, label: "post-run")

      StrategyState.put(agent, Map.put(strategy, :context, fitted))
    else
      _ -> agent
    end
  end

  # Mirrors `Jido.AI.Reasoning.ReAct.Strategy.active_run?/1`, which is private.
  defp active_run?(strategy) do
    is_binary(Map.get(strategy, :active_request_id)) and
      Map.get(strategy, :status) in [:awaiting_llm, :awaiting_tool]
  end

  @impl Jido.AI.ToolInterceptor
  def before_tool_call(tool_call, context) do
    MaterializationAliases.expand_tool_call(tool_call, context)
  end

  @impl Jido.AI.ToolInterceptor
  def after_tool_call(tool_call, result, context) do
    case MaterializationAliases.alias_tool_result(tool_call, result, context) do
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

    with {:ok, tools} <-
           Registry.resolve_modules(Skills.provisioned_tool_keys(configured_agent, skills)) do
      {:ok,
       %{
         tools: tools,
         # Merges system LLM sampling opts (temperature, top_p) as defaults until per-agent
         # advanced options are wired into ConfiguredAgent and surfaced in the BO UI.
         llm_opts: Keyword.merge(generation_opts(), ProviderSpec.llm_opts(configured_agent)),
         system_prompt: Skills.system_prompt(configured_agent, skills),
         # Carried on the agent so the post-run trim can read the budget without a
         # DB round-trip. The per-ask copy in `tool_context` is not usable there:
         # ReAct deletes `run_tool_context` as part of the terminal transition.
         memory_context_max_size: memory_context_max_size(configured_agent)
       }}
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

  def build_initial_context(%ConfiguredAgent{} = configured_agent, server_id, _context) do
    spawn_opts = spawn_opts_from_server_id(server_id)

    HistoryLoader.load_context(
      spawn_opts,
      max_tokens: memory_context_max_size(configured_agent),
      materialization_alias_scope: server_id
    )
  end

  @doc """
  Resolves the context-window token budget for a configured agent, defaulting when
  unset.

  This is the only place the number is derived. `runtime_config/1` then carries it
  onto the server, and every warm enforcement point reads it back from there rather
  than re-deriving it — so the per-turn transformer and the post-run trim cannot
  drift apart. `build_initial_context/3` calls this directly because the cold path
  runs before there is a server to read from.
  """
  @spec memory_context_max_size(ConfiguredAgent.t()) :: pos_integer()
  def memory_context_max_size(%ConfiguredAgent{memory_context_max_size: size})
      when is_integer(size) and size > 0,
      do: size

  def memory_context_max_size(%ConfiguredAgent{}), do: @default_memory_context_max_size

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
    with {:ok, config} <- server_runtime_config(server, configured_agent),
         :ok <- ensure_system_prompt(server, effective_system_prompt(configured_agent)) do
      ask_opts =
        opts
        |> Keyword.put(:llm_opts, Map.get(config, :llm_opts, []))
        |> Keyword.put(:max_iterations, configured_agent.max_iterations || 10)
        |> Keyword.put_new(:timeout, 300_000)
        |> maybe_put_tool_timeout(config)
        |> put_context_budget(context_budget(config, configured_agent))

      ask_stream(server, query, ask_opts)
    end
  end

  # The per-run `tool_context` is merged over the server's `base_tool_context` by
  # ReAct and handed to `RequestTransformer.transform_request/4` as the runtime
  # context — the one channel that carries per-agent config into a per-turn hook.
  # Merging (rather than replacing) preserves the keys ServerManager seeds at
  # spawn, e.g. `materialization_alias_scope`.
  defp put_context_budget(opts, budget) when is_integer(budget) and budget > 0 do
    tool_context =
      opts
      |> Keyword.get(:tool_context, %{})
      |> Map.put(:max_context_tokens, budget)

    Keyword.put(opts, :tool_context, tool_context)
  end

  # The budget resolved at spawn and carried on the server's runtime config, which
  # is what `trim_settled_context/1` reads too — so the per-turn transformer and
  # the post-run trim always enforce the same number. Falls back to the agent's own
  # value for a live server whose cached config predates the key.
  defp context_budget(config, %ConfiguredAgent{} = configured_agent) do
    case Map.get(config, :memory_context_max_size) do
      size when is_integer(size) and size > 0 -> size
      _ -> memory_context_max_size(configured_agent)
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

  # Recomputed on every ask so skill body/description edits propagate to live
  # servers through the existing compare-and-set in ensure_system_prompt/2.
  #
  # The CONTENT changed in Step 4 (a name/description index instead of every skill body);
  # the MECHANISM did not. `%Jido.AI.Skill.Spec{}` structs are consumed by
  # `Jido.AI.Skill.Prompt` and ZAQ's own `load_skill` action — they must never be passed
  # to `use Jido.AI.Agent`'s `:skills` option, which takes core `Jido.Skill` plugins with
  # a `skill_spec/1` callback. They are unrelated concepts with confusingly similar names.
  defp effective_system_prompt(configured_agent) do
    skills = Skills.enabled_for_agent(configured_agent)
    Skills.system_prompt(configured_agent, skills)
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
