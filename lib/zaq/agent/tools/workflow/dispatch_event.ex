defmodule Zaq.Agent.Tools.Workflow.DispatchEvent do
  @moduledoc """
  Workflow action: dispatches an allowlisted Engine event.

  ## Machine runs

  Set `machine: true` to mark the dispatched event as a machine (actorless)
  run. `Zaq.Engine.TriggerNode` reads the `"machine"` marker on the request and
  flips `source_event.assigns.skip_permissions = true` on the triggered run, so
  steps that authorize against the trusted context (e.g.
  `Zaq.Agent.Tools.Accounts.History`) accept their mapped `person_id` instead of
  requiring a human actor. The bypass is opt-in — a missing marker never grants
  it (see `Zaq.Engine.TriggerNode`).

  ## Example

      iex> Zaq.Agent.Tools.Workflow.DispatchEvent.run(
      ...>   %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
      ...>   %{}
      ...> )
      {:ok, %{dispatched: %{"email" => "a@b.com"}}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "dispatch_event",
    description: "Dispatch an allowlisted workflow event to the Engine node.",
    schema: [
      input: [type: :map, required: true, doc: "Request payload — passed as event request"],
      event_name: [
        type: :string,
        required: true,
        doc: "Allowlisted Engine event name, e.g. \"lead_identified\""
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
      dispatched: [type: :map, required: true, doc: "The request map that was dispatched"]
    ]

  require Logger

  alias Zaq.NodeRouter

  @allowed_event_names ~w(lead_identified)

  @impl Jido.Action
  def run(%{input: input, event_name: event_name} = params, ctx) do
    machine? = Map.get(params, :machine, false) == true

    Logger.debug(
      "[dispatch_event] run called event_name=#{inspect(event_name)} machine=#{machine?} input_keys=#{inspect(Map.keys(input))}"
    )

    case validate_event_name(event_name) do
      :ok ->
        dispatch_event(input, event_name, machine?, ctx)

      {:error, reason} ->
        Logger.warning("[dispatch_event] aborted before dispatch reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp dispatch_event(input, event_name, machine?, ctx) do
    # Stringify all keys — iterate pipeline may atom-normalize keys via try_to_atom,
    # leaving a mixed map that the engine rejects as {:invalid_request, ...}.
    request =
      input
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> maybe_mark_machine(machine?)

    event = Zaq.Event.new(request, :engine, type: :async, name: event_name)
    node_router = Map.get(ctx, :node_router, NodeRouter)

    Logger.debug("[dispatch_event] dispatching #{inspect(event.name)} to :engine")

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

  # The `"machine"` marker is read by `Zaq.Engine.TriggerNode` to set
  # skip_permissions on the triggered run. Only added when explicitly requested
  # so non-machine dispatches keep a clean request payload.
  defp maybe_mark_machine(request, true), do: Map.put(request, "machine", true)
  defp maybe_mark_machine(request, false), do: request

  defp validate_event_name(event_name) when event_name in @allowed_event_names, do: :ok

  defp validate_event_name(event_name) do
    {:error,
     "unsupported event_name #{inspect(event_name)}, allowed: #{Enum.join(@allowed_event_names, ", ")}"}
  end

  def allowed_event_names, do: @allowed_event_names
end
