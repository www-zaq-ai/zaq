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

  All other params in the accumulated workflow state are available as
  `{{variable_name}}` substitutions in `input`.

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
      ]
    ],
    output_schema: [
      output: [type: :string, required: true, doc: "Agent response text."]
    ]

  require Logger

  alias Zaq.Agent.StreamEvents
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(%{agent_id: agent_id, input: input} = params, context) do
    dispatch_agent_run(agent_id, input, params, context)
  end

  defp dispatch_agent_run(agent_id, input, params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)
    vars = build_vars(params)
    resolved_input = substitute(input, vars)

    resolved_input
    |> build_incoming(context)
    |> build_event(agent_id, context)
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
  defp build_incoming(content, context) do
    %Incoming{
      content: content,
      channel_id: channel_id(context),
      author_id: author_id(context),
      provider: nil,
      metadata: incoming_metadata(context)
    }
  end

  # Carry the run id (and step index, when present) as data when running as a
  # workflow node; nothing extra for a tool call (the standard person/identity scope
  # applies, and B != A by name). The step index lets `derive_scope/2` give each
  # `run_agent` step its own server (`"workflow:run:<run_id>:step:<step_index>"`), so
  # two run_agent steps in one run never contend on a shared server.
  defp incoming_metadata(context) do
    case run_id(context) do
      nil -> %{}
      run_id -> maybe_put_step_index(%{run_id: run_id}, context)
    end
  end

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

  defp build_event(incoming, agent_id, context) do
    incoming
    |> Event.new(:agent,
      opts: [
        action: :run_pipeline,
        pipeline_opts: [skip_permissions: skip_permissions?(context)]
      ]
    )
    |> Map.put(:assigns, %{"agent_selection" => %{"agent_id" => agent_id}})
    |> maybe_put_actor(context_actor(context))
  end

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

  # Mirrors Zaq.Agent.Pipeline.result_from_answering/3's field sourcing so the
  # same trace/agent/model/measurements shown for chat messages is available on
  # a run_agent step's StepRun.results — StepRunner persists this map verbatim,
  # and Jido's output validation merges undeclared keys through untouched, so
  # this needs no output_schema change. json_safe/1 is applied per-field (not to
  # the whole map) so the top-level `:output` key stays an atom — output_schema
  # matches known keys by atom, and stringifying it would make Jido treat the
  # required `output` field as missing.
  defp trace_result(outgoing) do
    %{
      output: outgoing.body,
      trace: outgoing.metadata |> Map.get(:trace, []) |> StreamEvents.json_safe(),
      agent: outgoing.metadata |> Map.get(:agent) |> json_safe_or_nil(),
      model: Map.get(outgoing.metadata, :model),
      measurements: outgoing.metadata |> Map.get(:measurements, %{}) |> StreamEvents.json_safe()
    }
  end

  # json_safe/1 treats `nil` as an atom (stringifying it to "nil") before it
  # reaches the is_nil clause — guard it out here rather than in the shared
  # helper, matching how Conversations.assistant_metadata/1 avoids the same
  # pitfall by rejecting nil values before calling json_safe.
  defp json_safe_or_nil(nil), do: nil
  defp json_safe_or_nil(value), do: StreamEvents.json_safe(value)

  # Build substitution vars from all params except the action-level ones.
  #
  # Nested maps (e.g. `row` as set by EnsurePerson) are spread one level deep
  # so their keys become top-level {{variable}} substitutions. Flat keys always
  # win over keys that came from a nested map. Internal workflow keys
  # (__cascade__) are excluded entirely.
  defp build_vars(params) do
    dropped =
      Map.drop(params, [:agent_id, :input, :__cascade__, "__cascade__"])

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
