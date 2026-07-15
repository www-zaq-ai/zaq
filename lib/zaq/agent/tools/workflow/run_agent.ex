defmodule Zaq.Agent.Tools.Workflow.RunAgent do
  @moduledoc """
  Runs a configured agent with template-variable substitution.

  Substitutes `{{variable}}` placeholders in `input` using all accumulated
  workflow params, then dispatches to the agent node.

  The agent is referenced by `agent_id`, mirroring how channels point to agents:
  the action holds the identifier and dispatches it via `agent_selection`. It does
  not load or verify the agent — the agent node resolves and validates it through
  the same path channels use, and surfaces any failure in the response.

  The configured agent owns its system prompt and model. All run-specific/custom
  data belongs in `input` (the user message), never in a prompt override.

  ## What this tool does (and does not do)

  Like a channel, `run_agent` only builds a correct `%Incoming{}` carrying identity
  as **data** and dispatches `:run_pipeline` — it does **not** decide how the agent
  server is scoped or spawned. Scope derivation is owned by
  `Zaq.Agent.Executor.derive_scope/2`; spawn/history mapping by
  `Zaq.Agent.Factory`.

  The run-specific data the incoming carries is `metadata.run_id` and, when running
  as a workflow node, `metadata.step_index` (the workflow run id and the node's step
  index). `derive_scope/2` turns those into `"workflow:run:<run_id>:step:<step_index>"`
  (or `"workflow:run:<run_id>"` when no step index is present) so each `run_agent`
  step gets its own Jido server instead of collapsing onto the shared `"anonymous"`
  scope and contending (`:busy`). Different runs — and different run_agent steps
  within a run — are isolated.

  - **Workflow node** (context has `:run_id`) → incoming carries `metadata.run_id`.
  - **Agent tool call** (context has the parent `:incoming`, e.g. Agent A's LLM
    calls `run_agent` to run Agent B) → no run marker; the standard person/identity
    scope applies. B is a different agent name, so it cannot collide with A.

  Identity and permissions also flow from the context as data: the triggering
  `:actor` is forwarded onto the event, and `skip_permissions` is taken from the
  context (explicit opt-in) rather than assumed.

  ## Schema

  - `agent_id` — required. ID of the configured agent (same identifier channels use).
  - `input`    — required. The user message / task prompt (supports `{{variable}}`).
  - `context`  — optional. Ordered list of prior turns to seed the agent. Each turn
    is a **string-keyed map** (not a tuple), e.g.
    `%{"role" => "user", "content" => "hi"}`, where `"role"` is `"user"`,
    `"assistant"`, or `"tool"` and `"content"` supports `{{variable}}` — the unified
    role/content vocabulary shared with `Zaq.Agent.History` / ReqLLM / Jido.AI, and
    the exact shape `Accounts.History` emits in its `messages` field. Role-specific
    extra keys: `"assistant"` may add `"tool_calls"`; `"tool"` may add
    `"tool_call_id"` and `"name"` (see `normalize_context_entry/2`). This tool builds
    the turns into a `Jido.AI.Context` (`build_context/2`) and passes it on the event's
    `pipeline_opts[:context]`; `Factory.build_initial_context/3` uses it as the agent's
    entire cold-start context (skipping history loading) when the server spawns.
  - `context_max_size` — optional positive integer. Token budget for the seeded
    context (default 5000). When the seed turns exceed it, the **oldest** turns are
    dropped (newest kept) via `Zaq.Agent.TokenEstimator` in `build_context/2` before
    the `Jido.AI.Context` is assembled, so a seeded context never blows past its
    ceiling — mirroring the budget `HistoryLoader` applies on the history path. Also
    carried as data on `metadata.context_max_size` for downstream observability.

  All other params in the accumulated workflow state are available as
  `{{variable_name}}` substitutions in `input` (and in each context turn's `content`).

  ## Example

      RunAgent.run(
        %{agent_id: 42, input: "Draft email for {{name}} at {{company}}",
          name: "John", company: "Acme"},
        %{run_id: "run-123"}
      )
      # => {:ok, %{output: "Hi John..."}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "run_agent",
    description: "Run a configured agent with template-variable substitution.",
    schema: [
      agent_id: [type: :integer, required: true, doc: "ID of the configured agent."],
      input: [
        type: :string,
        required: true,
        doc: "Task/user message. Supports {{variable}} substitution."
      ],
      context: [
        # {:list, :any}, not {:list, :map}: as an LLM tool, args arrive as
        # string-keyed maps decoded from JSON, and NimbleOptions' :map type rejects
        # non-atom keys. Each entry's shape is validated in normalize_context_entry/2.
        type: {:list, :any},
        required: false,
        default: [],
        doc:
          ~s|Ordered prior turns to seed the agent. Each entry is a string-keyed map | <>
            ~s|whose "role" is "user", "assistant", or "tool", plus "content" | <>
            ~s|(supports {{variable}}). Extra keys depend on the role: "assistant" may | <>
            ~s|add "tool_calls"; "tool" may add "tool_call_id" and "name". | <>
            ~s|E.g. %{"role" => "user", "content" => "hi"}.|
      ],
      context_max_size: [
        type: :integer,
        required: false,
        doc:
          "Optional token budget for the seeded context (default 5000). When the " <>
            "seed turns exceed it, the oldest are dropped (newest kept) before the " <>
            "context is built."
      ]
    ],
    output_schema: [
      output: [type: :string, required: true, doc: "Agent response text."]
    ]

  require Logger

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.StreamEvents
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.NodeRouter

  # Default seed-context token budget when a run does not set `context_max_size`.
  # Kept in step with `HistoryLoader`'s default so both context paths share a ceiling.
  @default_context_max_size 5_000

  @impl Jido.Action
  # Params may arrive atom- OR string-keyed. The workflow DAG builder atomizes a
  # node's top-level param keys only when EVERY key is an existing atom; a single
  # non-atom key makes it leave the whole map string-keyed
  # (`DagBuilder.atomize_keys/1`). Read both shapes so a stray param key never
  # crashes the tool with a FunctionClauseError.
  def run(params, context) when is_map(params) do
    dispatch_agent_run(
      fetch_param(params, :agent_id),
      fetch_param(params, :input),
      params,
      context
    )
  end

  defp dispatch_agent_run(agent_id, input, params, context) do
    node_router = node_router(context)
    vars = build_vars(params)
    resolved_input = substitute(input, vars)
    ai_context = build_context(params, vars)
    context_max_size = context_max_size(params)

    resolved_input
    |> build_incoming(context, context_max_size)
    |> build_event(agent_id, context, ai_context)
    |> node_router.dispatch()
    |> Map.get(:response)
    |> handle_response()
  end

  # provider: nil keeps this a node-internal request — the agent node's
  # `:run_pipeline` handler runs its pre-run verification (identity, prompt
  # guard, scoping) and returns the %Outgoing{} directly instead of routing it
  # to a delivery channel.
  #
  # metadata.run_id (and metadata.step_index) carry the run/step identity as data
  # only. The scope decision belongs to Executor.derive_scope/2, which maps them to
  # "workflow:run:<run_id>:step:<step_index>" — one isolated agent server per step.
  defp build_incoming(content, context, context_max_size) do
    %Incoming{
      content: content,
      channel_id: channel_id(context),
      author_id: author_id(context),
      provider: nil,
      metadata: incoming_metadata(context, context_max_size)
    }
  end

  # Carry the run id (and step index, when present) as data when running as a
  # workflow node; nothing extra for a tool call (the standard person/identity scope
  # applies, and B != A by name). The step index lets `derive_scope/2` give each
  # `run_agent` step its own server (`"workflow:run:<run_id>:step:<step_index>"`), so
  # two run_agent steps in one run never contend on a shared server.
  defp incoming_metadata(context, context_max_size) do
    context
    |> run_markers()
    |> maybe_put_context_max_size(context_max_size)
  end

  defp run_markers(context) do
    case run_id(context) do
      nil -> %{}
      run_id -> maybe_put_step_index(%{run_id: run_id}, context)
    end
  end

  # Only a positive integer is carried. The budget is applied at build time in
  # `build_context/2`; this carry is retained as data for downstream observability.
  defp maybe_put_context_max_size(metadata, nil), do: metadata

  defp maybe_put_context_max_size(metadata, size) when is_integer(size) and size > 0,
    do: Map.put(metadata, :context_max_size, size)

  defp maybe_put_step_index(metadata, context) do
    case step_index(context) do
      nil -> metadata
      step_index -> Map.put(metadata, :step_index, step_index)
    end
  end

  defp step_index(context) do
    case Map.get(context, :step_index) || Map.get(context, "step_index") do
      index when is_integer(index) -> index
      _ -> nil
    end
  end

  # Author identity comes from the execution context's actor (the person who
  # triggered the run / parent agent call), never a fabricated literal. nil when
  # there is no person — the agent node also receives the actor on the event, so
  # this only keeps the incoming consistent and avoids stamping a bogus id onto a
  # real actor via ActorNormalizer.put_actor_defaults/2.
  defp author_id(context) do
    case ActorNormalizer.person_id(context_actor(context)) do
      nil -> nil
      person_id -> to_string(person_id)
    end
  end

  defp build_event(incoming, agent_id, context, ai_context) do
    incoming
    |> Event.new(:agent,
      opts: [
        action: :run_pipeline,
        pipeline_opts: pipeline_opts(context, ai_context)
      ]
    )
    |> Map.put(:assigns, %{"agent_selection" => %{"agent_id" => agent_id}})
    |> maybe_put_actor(context_actor(context))
  end

  # `:context` is only present when the caller supplied seed turns — its absence
  # keeps the standard history-loading path in `Factory.build_initial_context/3`.
  defp pipeline_opts(context, nil), do: [skip_permissions: skip_permissions?(context)]

  defp pipeline_opts(context, %AIContext{} = ai_context),
    do: [skip_permissions: skip_permissions?(context), context: ai_context]

  defp channel_id(context) do
    case run_id(context) do
      nil -> parent_channel_id(context)
      run_id -> "workflow:#{run_id}"
    end
  end

  defp parent_channel_id(context) do
    case parent_incoming(context) do
      %Incoming{channel_id: cid} when is_binary(cid) -> cid
      _ -> "workflow:anon"
    end
  end

  defp run_id(context), do: Map.get(context, :run_id) || Map.get(context, "run_id")

  defp parent_incoming(context) do
    case Map.get(context, :incoming) || Map.get(context, "incoming") do
      %Incoming{} = incoming -> incoming
      _ -> nil
    end
  end

  defp context_actor(context), do: Map.get(context, :actor) || Map.get(context, "actor")

  # An explicit `:node_router` in the step context always wins (agent-tool-call
  # path, unit tests); otherwise the live `NodeRouter` is used. This mirrors how the
  # other agent tools resolve their router (`search_knowledge_base`,
  # `knowledge_base_overview`) — injection through the step context as data, never an
  # app-env seam. Workflow steps carry no router (StepRunner injects none) and so use
  # the live `NodeRouter`.
  defp node_router(context), do: Map.get(context, :node_router, NodeRouter)

  # skip_permissions is an explicit opt-in flowing from the execution context
  # (machine event runs set it; human-triggered runs do not). Never granted
  # implicitly — a missing flag means the child runs with the caller's permissions.
  defp skip_permissions?(context),
    do: (Map.get(context, :skip_permissions) || Map.get(context, "skip_permissions")) == true

  defp maybe_put_actor(event, nil), do: event
  defp maybe_put_actor(event, actor), do: Map.put(event, :actor, actor)

  defp handle_response(%Outgoing{} = outgoing) do
    if error_metadata?(outgoing.metadata) do
      reason = outgoing.metadata[:reason] || "unknown"
      {:error, "agent_failed:#{reason}"}
    else
      {:ok, trace_result(outgoing)}
    end
  end

  defp handle_response({:error, reason}), do: {:error, "agent_failed:#{inspect(reason)}"}
  defp handle_response(other), do: {:error, "agent_failed:#{inspect(other)}"}

  defp error_metadata?(metadata), do: is_map(metadata) and metadata[:error]

  # StepRunner persists this map verbatim, and Jido's output validation merges
  # undeclared keys through untouched, so no output_schema change is needed.
  # Top-level keys stay atoms — output_schema matches known keys by atom, and
  # stringifying `output` would make Jido treat the required field as missing.
  defp trace_result(outgoing) do
    outgoing.metadata
    |> StreamEvents.telemetry_fields(json_safe: true)
    |> Map.put(:output, outgoing.body)
  end

  # Build the optional `context` param into a `Jido.AI.Context`, or nil when the
  # caller supplied none (so the agent falls back to normal history loading). The
  # built context becomes the agent's entire cold-start context —
  # `Factory.build_initial_context/3` uses it as-is, applying no further budget — so
  # the token budget is enforced here, before assembly, by dropping the oldest turns
  # that overflow `context_max_size` (default 5000).
  defp build_context(params, vars) do
    case build_context_messages(params, vars) do
      [] ->
        nil

      messages ->
        case within_budget(messages, context_budget(params)) do
          [] -> nil
          kept -> AIContext.new() |> AIContext.append_messages(kept)
        end
    end
  end

  defp context_budget(params), do: context_max_size(params) || @default_context_max_size

  # Keep the most recent turns that fit within `max_tokens`, dropping the oldest
  # first while preserving chronological order. Mirrors `HistoryLoader`'s budget
  # policy so a seeded context honors the same token ceiling as loaded history.
  defp within_budget(messages, max_tokens) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn msg, {acc, total} ->
      new_total = total + TokenEstimator.estimate(msg.content || "")

      if new_total > max_tokens do
        {:halt, {acc, total}}
      else
        {:cont, {[msg | acc], new_total}}
      end
    end)
    |> elem(0)
  end

  # Normalise the optional `context` param into an ordered list of role-keyed turn
  # maps (`role: "user" | "assistant" | "tool"`) — the unified role/content
  # vocabulary shared with `Zaq.Agent.History`, ReqLLM, and Jido.AI. `content` gets
  # the same {{variable}} substitution as `input`; entries with an unsupported/missing
  # role, or non-map entries, are dropped rather than failing the run.
  defp build_context_messages(params, vars) do
    params
    |> fetch_param(:context, [])
    |> List.wrap()
    |> Enum.flat_map(&normalize_context_entry(&1, vars))
  end

  defp normalize_context_entry(entry, vars) when is_map(entry) do
    content = entry |> entry_field(:content) |> to_string_safe() |> substitute(vars)

    case normalize_role(entry_field(entry, :role)) do
      "user" ->
        [%{role: "user", content: content}]

      "assistant" ->
        [%{role: "assistant", content: content, tool_calls: entry_field(entry, :tool_calls)}]

      "tool" ->
        [
          %{
            role: "tool",
            content: content,
            tool_call_id: entry_field(entry, :tool_call_id),
            name: entry_field(entry, :name)
          }
        ]

      other ->
        Logger.warning(
          "[RunAgent] dropping context turn with unsupported role: #{inspect(other)}"
        )

        []
    end
  end

  defp normalize_context_entry(other, _vars) do
    Logger.warning("[RunAgent] dropping non-map context turn: #{inspect(other)}")
    []
  end

  # Accept an integer, or a numeric string (JSONB/tool-call args may deliver either).
  # Anything non-positive or unparseable becomes nil so the agent layer falls back to
  # the agent's configured budget.
  defp context_max_size(params) do
    case fetch_param(params, :context_max_size) do
      n when is_integer(n) and n > 0 -> n
      n when is_binary(n) -> parse_positive_int(n)
      _ -> nil
    end
  end

  defp parse_positive_int(string) do
    case Integer.parse(string) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp normalize_role(role) when is_binary(role), do: role
  defp normalize_role(role) when is_atom(role) and not is_nil(role), do: Atom.to_string(role)
  defp normalize_role(_), do: nil

  # Accept both atom and string keys (workflow data is atom-keyed in-process,
  # string-keyed after a JSONB round-trip).
  defp entry_field(entry, key) when is_atom(key),
    do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp fetch_param(params, key), do: fetch_param(params, key, nil)

  defp fetch_param(params, key, default) when is_atom(key),
    do: Map.get(params, key) || Map.get(params, Atom.to_string(key)) || default

  # Build substitution vars from all params except the action-level ones.
  #
  # Nested maps (e.g. `row` as set by EnsurePerson) are spread one level deep
  # so their keys become top-level {{variable}} substitutions. Flat keys always
  # win over keys that came from a nested map. Internal workflow keys
  # (__cascade__) and the structured `context` param are excluded entirely.
  defp build_vars(params) do
    dropped =
      Map.drop(params, [
        :agent_id,
        :input,
        :context,
        :context_max_size,
        :__cascade__,
        "agent_id",
        "input",
        "context",
        "context_max_size",
        "__cascade__"
      ])

    nested_vars =
      dropped
      |> Enum.flat_map(fn
        {_k, v} when is_map(v) ->
          Enum.map(v, fn {nk, nv} -> {to_string(nk), to_string_safe(nv)} end)

        _ ->
          []
      end)
      |> Map.new()

    flat_vars =
      dropped
      |> Enum.reject(fn {_k, v} -> is_map(v) end)
      |> Map.new(fn {k, v} -> {to_string(k), to_string_safe(v)} end)

    Map.merge(nested_vars, flat_vars)
  end

  defp substitute(template, vars) when is_binary(template) do
    Regex.replace(~r/\{\{(\w+)\}\}/, template, fn _, key ->
      Map.get(vars, key, "")
    end)
  end

  defp to_string_safe(v) when is_binary(v), do: v
  defp to_string_safe(v) when is_integer(v), do: Integer.to_string(v)
  defp to_string_safe(v) when is_float(v), do: Float.to_string(v)
  defp to_string_safe(v) when is_boolean(v), do: to_string(v)
  defp to_string_safe(nil), do: ""
  defp to_string_safe(v), do: inspect(v)
end
