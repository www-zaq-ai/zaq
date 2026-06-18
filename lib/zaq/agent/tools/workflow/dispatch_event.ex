defmodule Zaq.Agent.Tools.Workflow.DispatchEvent do
  @moduledoc """
  Workflow action: dispatches an allowlisted Engine event.

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
      ]
    ],
    output_schema: [
      dispatched: [type: :map, required: true, doc: "The request map that was dispatched"]
    ]

  require Logger

  alias Zaq.NodeRouter

  @allowed_event_names ~w(lead_identified)

  @impl Jido.Action
  def run(%{input: input, event_name: event_name}, ctx) do
    Logger.debug(
      "[dispatch_event] run called event_name=#{inspect(event_name)} input_keys=#{inspect(Map.keys(input))}"
    )

    case validate_event_name(event_name) do
      :ok ->
        dispatch_event(input, event_name, ctx)

      {:error, reason} ->
        Logger.warning("[dispatch_event] aborted before dispatch reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp dispatch_event(input, event_name, ctx) do
    # Stringify all keys — iterate pipeline may atom-normalize keys via try_to_atom,
    # leaving a mixed map that the engine rejects as {:invalid_request, ...}.
    request = Map.new(input, fn {k, v} -> {to_string(k), v} end)
    event = Zaq.Event.new(request, :engine, type: :async, name: event_name)
    node_router = Map.get(ctx, :node_router, NodeRouter)

    Logger.debug(
      "[dispatch_event] dispatching event_name=#{inspect(event.name)} destination=:engine"
    )

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

  defp validate_event_name(event_name) when event_name in @allowed_event_names, do: :ok

  defp validate_event_name(event_name) do
    {:error,
     "unsupported event_name #{inspect(event_name)}, allowed: #{Enum.join(@allowed_event_names, ", ")}"}
  end

  @doc false
  def allowed_event_names, do: @allowed_event_names
end
