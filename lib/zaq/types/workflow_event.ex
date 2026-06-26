defmodule Zaq.Types.WorkflowEvent do
  @moduledoc """
  Custom Ecto type that casts, dumps, and loads `%Zaq.Event{}` structs to/from
  the JSONB `source_event` column in `workflow_runs`.

  `Zaq.Event` is a plain Elixir struct and must not become an Ecto embedded
  schema — it is a cross-node routing envelope used outside of persistence.
  This type bridges it to the DB without coupling the routing layer to Ecto.

  On `load/1` (reading from DB): string-key map → `%Zaq.Event{}`
  On `dump/1` (writing to DB):   `%Zaq.Event{}` → plain serializable map
  On `cast/1` (changeset input): accepts `%Zaq.Event{}` or any map
  """

  use Ecto.Type

  alias Zaq.Event

  @impl true
  def type, do: :map

  @impl true
  def cast(%Event{} = event), do: {:ok, event}

  def cast(map) when is_map(map) do
    {:ok,
     %Event{
       request: Zaq.MapUtils.fetch_either(map, :request, "request"),
       assigns: Zaq.MapUtils.fetch_either(map, :assigns, "assigns") || %{},
       response: Zaq.MapUtils.fetch_either(map, :response, "response"),
       hops: Zaq.MapUtils.fetch_either(map, :hops, "hops") || [],
       next_hop: Zaq.MapUtils.fetch_either(map, :next_hop, "next_hop"),
       trace_id: Zaq.MapUtils.fetch_either(map, :trace_id, "trace_id"),
       opts: Zaq.MapUtils.fetch_either(map, :opts, "opts") || [],
       version: Zaq.MapUtils.fetch_either(map, :version, "version") || 1,
       actor: Zaq.MapUtils.fetch_either(map, :actor, "actor")
     }}
  end

  def cast(_), do: :error

  @impl true
  def dump(%Event{} = event) do
    map = %{
      "request" => dump_value(event.request),
      "assigns" => dump_value(event.assigns),
      "response" => dump_value(event.response),
      "hops" => Enum.map(event.hops || [], &dump_hop/1),
      "next_hop" => dump_hop(event.next_hop),
      "trace_id" => event.trace_id,
      "opts" => dump_value(event.opts),
      "version" => event.version,
      "actor" => dump_value(event.actor)
    }

    {:ok, map}
  end

  def dump(map) when is_map(map), do: {:ok, map}
  def dump(_), do: :error

  defp dump_hop(nil), do: nil

  defp dump_hop(%Zaq.EventHop{} = hop) do
    %{
      "destination" => Atom.to_string(hop.destination),
      "type" => Atom.to_string(hop.type),
      "timestamp" => DateTime.to_iso8601(hop.timestamp)
    }
  end

  defp dump_hop(map) when is_map(map), do: map

  defp dump_value(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> dump_value()
  end

  defp dump_value(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {dump_key(key), dump_value(value)} end)
  end

  defp dump_value(list) when is_list(list) do
    Enum.map(list, &dump_value/1)
  end

  defp dump_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> dump_value()
  end

  # defp dump_value(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp dump_value(value), do: value

  # defp dump_key(key) when is_atom(key), do: Atom.to_string(key)
  defp dump_key(key), do: key

  @impl true
  def load(map) when is_map(map) do
    cast(map)
  end

  def load(_), do: :error

  @impl true
  def equal?(%Event{trace_id: t1}, %Event{trace_id: t2}), do: t1 == t2
  def equal?(a, b), do: a == b
end
