defmodule Zaq.Agent.Tools.Workflow.DispatchEvent do
  @moduledoc """
  Workflow action: builds a `Zaq.Event` and dispatches it via `NodeRouter`.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.DispatchEvent.run(
      ...>   %{input: %{"email" => "a@b.com"}, destination: "engine", name: "lead_identified"},
      ...>   %{}
      ...> )
      {:ok, %{dispatched: %{"email" => "a@b.com"}}}
  """

  use Jido.Action,
    name: "dispatch_event",
    description: "Build a Zaq.Event from input and dispatch it via NodeRouter.",
    schema: [
      input: [type: :map, required: true, doc: "Request payload — passed as event request"],
      destination: [
        type: :string,
        required: true,
        doc: "NodeRouter destination atom, e.g. \"engine\""
      ],
      name: [
        type: :string,
        required: false,
        doc: "Optional event name atom, e.g. \"lead_identified\""
      ],
      type: [
        type: :string,
        required: false,
        default: "sync",
        doc: "Hop type: \"sync\" or \"async\""
      ]
    ],
    output_schema: [
      dispatched: [type: :map, required: true, doc: "The request map that was dispatched"]
    ]

  use Zaq.Engine.Workflows.Action

  require Logger

  alias Zaq.NodeRouter

  @destinations %{
    "engine" => :engine,
    "channels" => :channels,
    "ingestion" => :ingestion,
    "agent" => :agent
  }

  @hop_types %{"sync" => :sync, "async" => :async}

  @impl Jido.Action
  def run(%{input: input, destination: destination} = params, ctx) do
    Logger.debug(
      "[dispatch_event] run called destination=#{inspect(destination)} name=#{inspect(Map.get(params, :name))} input_keys=#{inspect(Map.keys(input))}"
    )

    with {:ok, dest_atom} <- resolve(:destination, destination),
         {:ok, opts} <- build_opts(params) do
      # Stringify all keys — iterate pipeline may atom-normalize keys via try_to_atom,
      # leaving a mixed map that the engine rejects as {:invalid_request, ...}.
      request = Map.new(input, fn {k, v} -> {to_string(k), v} end)
      event = Zaq.Event.new(request, dest_atom, opts)
      node_router = Map.get(ctx, :node_router, NodeRouter)

      Logger.debug(
        "[dispatch_event] dispatching event_name=#{inspect(event.name)} destination=#{inspect(dest_atom)}"
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
    else
      {:error, reason} ->
        Logger.warning("[dispatch_event] aborted before dispatch reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_opts(params) do
    with {:ok, opts} <- resolve_name([], Map.get(params, :name)) do
      {:ok, put_type(opts, Map.get(params, :type, "sync"))}
    end
  end

  defp resolve_name(opts, nil), do: {:ok, opts}

  # EventRegistry.derive_base_name/1 accepts both atom and binary event names.
  # Storing the name as a string avoids any atom-interning requirement and
  # satisfies the iron law — no String.to_atom/1 or String.to_existing_atom/1 needed.
  defp resolve_name(opts, name) when is_binary(name) do
    {:ok, Keyword.put(opts, :name, name)}
  end

  defp resolve(:destination, v) do
    case Map.fetch(@destinations, v) do
      {:ok, atom} ->
        {:ok, atom}

      :error ->
        {:error,
         "unknown destination #{inspect(v)}, allowed: #{Map.keys(@destinations) |> Enum.join(", ")}"}
    end
  end

  defp put_type(opts, type) do
    case Map.fetch(@hop_types, type) do
      {:ok, atom} -> Keyword.put(opts, :type, atom)
      :error -> opts
    end
  end
end
