defmodule Zaq.Agent.Tools.Workflow.DispatchEvent do
  @moduledoc """
  Workflow action: dispatches an event to a node role (the Engine by default).

  `event_name` is free-form — any non-blank name may be dispatched. The target
  node decides which events it consumes; this action does not gate names.

  ## Destination

  `destination` selects the target node role and is **optional** — it defaults to
  `"engine"`. Allowed values: `engine`, `agent`, `channels`, `ingestion`, `bo`.
  An unknown destination is rejected before dispatch.

  ## Machine runs

  Set `machine: true` to mark the dispatched event as a machine (actorless)
  run. `Zaq.Engine.TriggerNode` reads the `"machine"` marker on the request and
  flips `source_event.assigns.skip_permissions = true` on the triggered run, so
  steps that authorize against the trusted context (e.g.
  `Zaq.Agent.Tools.Accounts.History`) accept their mapped `person_id` instead of
  requiring a human actor. The bypass is opt-in — a missing marker never grants
  it (see `Zaq.Engine.TriggerNode`).

  ## Request payload

  By default the dispatched request is the **merged output of every previously
  executed step** — the run's cascade (`%{step_name => result}`) flattened into a
  single map. A `DispatchEvent` node can therefore sit anywhere in a workflow
  (e.g. as the second node) with no incoming `input` mapping and still forward
  the accumulated workflow state. Engine-internal plumbing keys (`__cascade__`,
  `__map_index__`, …) are stripped; only real domain data is dispatched.

  The optional `input` map is **layered on top** of those prior outputs and wins
  on key conflicts — use it to add or override fields. With no prior steps and no
  `input`, an empty request (`%{}`) is dispatched.

  A **scalar `input`** (e.g. a string) is dispatched **verbatim** as the request,
  bypassing the cascade merge and machine marker — handy for a plain message
  payload, e.g. `input: "seeds ready"` with `destination: "channels"`.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.DispatchEvent.run(
      ...>   %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
      ...>   %{}
      ...> )
      {:ok, %{dispatched: %{"email" => "a@b.com"}}}

      iex> Zaq.Agent.Tools.Workflow.DispatchEvent.run(
      ...>   %{event_name: "lead_identified"},
      ...>   %{}
      ...> )
      {:ok, %{dispatched: %{}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "dispatch_event",
    description: "Dispatch a workflow event to the Engine node.",
    schema: [
      input: [
        # `:any` — a map is merged on top of prior step outputs (string keys, so an
        # LLM tool call's string-keyed payload validates via `Jido.Exec.run`); a
        # scalar (e.g. a channels message string) is dispatched verbatim.
        type: :any,
        required: false,
        default: %{},
        doc:
          "Request payload. A map is layered on top of the merged outputs of prior steps (wins on conflicts); a scalar (e.g. a string) is dispatched as-is. Defaults to an empty map."
      ],
      event_name: [
        type: :string,
        required: true,
        doc: "Engine event name to dispatch, e.g. \"lead_identified\""
      ],
      destination: [
        type: :string,
        required: false,
        default: "engine",
        doc:
          "Target node role: engine, agent, channels, ingestion, or bo. Defaults to \"engine\"."
      ],
      machine: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "Mark the dispatched event as a machine (actorless) run, setting skip_permissions on the triggered run."
      ]
    ],
    output_schema: [
      # `:any` — the dispatched request is a string-keyed map or a scalar (see
      # run/2); the bare `:map` (atom-key-only) would reject either on validation.
      dispatched: [
        type: :any,
        required: true,
        doc: "The request that was dispatched (a map, or a scalar for verbatim payloads)"
      ]
    ]

  require Logger

  alias Zaq.NodeRouter

  # Allowlisted node roles a workflow may dispatch to. String-keyed so a
  # workflow/LLM-supplied name resolves without `String.to_atom` (atom-exhaustion
  # safe); an atom destination is normalised back through the same table.
  @destinations %{
    "engine" => :engine,
    "agent" => :agent,
    "channels" => :channels,
    "ingestion" => :ingestion,
    "bo" => :bo
  }

  @impl Jido.Action
  def run(%{event_name: event_name} = params, ctx) do
    input = Map.get(params, :input)
    machine? = Map.get(params, :machine, false) == true
    destination = Map.get(params, :destination) || "engine"

    Logger.debug(
      "[dispatch_event] run called event_name=#{inspect(event_name)} destination=#{inspect(destination)} machine=#{machine?} input=#{inspect(input)}"
    )

    with :ok <- validate_event_name(event_name),
         {:ok, dest} <- resolve_destination(destination) do
      dispatch_event(input, event_name, dest, machine?, ctx)
    else
      {:error, reason} ->
        Logger.warning("[dispatch_event] aborted before dispatch reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp dispatch_event(input, event_name, destination, machine?, ctx) do
    request = build_request(input, machine?, ctx)
    event = Zaq.Event.new(request, destination, type: :async, name: event_name)
    node_router = Map.get(ctx, :node_router, NodeRouter)

    Logger.debug("[dispatch_event] dispatching #{inspect(event.name)} to #{inspect(destination)}")

    case node_router.dispatch(event).response do
      {:ok, _} ->
        Logger.debug("[dispatch_event] dispatch succeeded")
        {:ok, %{dispatched: request}}

      nil ->
        # async dispatch — event was published, no sync response expected
        Logger.debug("[dispatch_event] async dispatch enqueued")
        {:ok, %{dispatched: request}}

      {:error, reason} ->
        Logger.warning("[dispatch_event] dispatch failed reason=#{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # A scalar `input` (string, number, …) is dispatched verbatim as the request —
  # e.g. a plain channels message. Cascade merging and the machine marker only
  # apply to map payloads, so a scalar bypasses both.
  defp build_request(input, _machine?, _ctx) when not is_map(input) and not is_nil(input),
    do: input

  # Map (or absent) `input`: default to the merged outputs of every previously
  # executed step (the run's `__cascade__`), so a DispatchEvent node forwards the
  # accumulated workflow state without an explicit `input` mapping. Explicit
  # `input` fields are layered on top and win on key conflicts.
  #
  # All keys are stringified — the iterate pipeline may atom-normalize keys via
  # try_to_atom, leaving a mixed map that the engine rejects as
  # {:invalid_request, ...}.
  defp build_request(input, machine?, ctx) do
    ctx
    |> prior_step_outputs()
    |> Map.merge(string_keyed(input || %{}))
    |> maybe_mark_machine(machine?)
  end

  # Flattens the run's cascade (`%{step_name => result}`) into a single
  # string-keyed map of every prior step's output. Internal plumbing keys
  # (`__cascade__`, `__map_index__`, …) are dropped so only real domain data is
  # dispatched. Key conflicts between steps resolve in `Map.merge` order.
  defp prior_step_outputs(ctx) do
    ctx
    |> Map.get(:__cascade__, Map.get(ctx, "__cascade__", %{}))
    |> Map.values()
    |> Enum.reduce(%{}, fn result, acc -> Map.merge(acc, string_keyed(result)) end)
  end

  # Stringifies a map's keys and drops engine-internal `__*` plumbing keys.
  defp string_keyed(map) when is_map(map) do
    map
    |> Enum.reject(fn {k, _v} -> internal_key?(k) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp string_keyed(_), do: %{}

  defp internal_key?(k), do: k |> to_string() |> String.starts_with?("__")

  # The `"machine"` marker is read by `Zaq.Engine.TriggerNode` to set
  # skip_permissions on the triggered run. Only added when explicitly requested
  # so non-machine dispatches keep a clean request payload.
  defp maybe_mark_machine(request, true), do: Map.put(request, "machine", true)
  defp maybe_mark_machine(request, false), do: request

  defp validate_event_name(event_name) when is_binary(event_name) do
    if String.trim(event_name) == "", do: {:error, "event_name must not be blank"}, else: :ok
  end

  defp validate_event_name(event_name),
    do: {:error, "event_name must be a string, got: #{inspect(event_name)}"}

  # Resolves a destination (string or atom) to an allowlisted node role atom.
  defp resolve_destination(destination) when is_atom(destination),
    do: resolve_destination(Atom.to_string(destination))

  defp resolve_destination(destination) when is_binary(destination) do
    case Map.fetch(@destinations, destination) do
      {:ok, role} ->
        {:ok, role}

      :error ->
        {:error,
         "unsupported destination #{inspect(destination)}, allowed: #{Enum.join(Map.keys(@destinations), ", ")}"}
    end
  end

  defp resolve_destination(other),
    do: {:error, "destination must be a string, got: #{inspect(other)}"}
end
