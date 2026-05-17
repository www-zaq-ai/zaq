defmodule Zaq.Engine.EventRegistry do
  @moduledoc """
  Subscribes to all events dispatched via NodeRouter and fires triggers
  when a known trigger event name passes through.

  State: a map with two keys:
  - `:events`   — `%{event_name_string => boolean}` (true = known trigger, false = seen but not a trigger)
  - `:fire_fn`  — `(event_name, event -> :ok)` — defaults to `TriggerNode.fire/2`,
                   injectable via `opts` for tests.

  On init, loads all enabled trigger `event_name` values from the DB and marks
  them `true` in the `:events` map. On each incoming event:
  - If `event.name` is nil → ignored
  - If `events[event_name] == true` → delegates to `fire_fn`
  - Otherwise → stores the event name as `false`
  """

  use GenServer

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.{TriggerNode, Workflows}

  @pubsub Zaq.PubSub
  @topic "node_router:events"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns all known events as a list of maps. Optionally filter with `is_trigger: true | false`."
  @spec list_events(keyword(), GenServer.server()) :: [%{name: String.t(), is_trigger: boolean()}]
  def list_events(opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:list_events, opts})
  end

  @doc "Marks an event_name as disabled (false) in the registry state."
  @spec deactivate(String.t(), GenServer.server()) :: :ok
  def deactivate(event_name, server \\ __MODULE__) when is_binary(event_name) do
    GenServer.call(server, {:set_event, event_name, false})
  end

  @doc "Marks an event_name as enabled (true) in the registry state."
  @spec activate(String.t(), GenServer.server()) :: :ok
  def activate(event_name, server \\ __MODULE__) when is_binary(event_name) do
    GenServer.call(server, {:set_event, event_name, true})
  end

  @impl true
  def init(opts) do
    if caller = Keyword.get(opts, :caller) do
      Sandbox.allow(Zaq.Repo, caller, self())
    end

    Phoenix.PubSub.subscribe(@pubsub, @topic)
    fire_fn = Keyword.get(opts, :trigger_node_fn, &TriggerNode.fire/2)
    events = load_trigger_state()
    {:ok, %{events: events, fire_fn: fire_fn}}
  end

  @impl true
  def handle_call({:list_events, opts}, _from, state) do
    result =
      state.events
      |> Enum.map(fn {name, is_trigger} -> %{name: name, is_trigger: is_trigger} end)
      |> maybe_filter(opts[:is_trigger])

    {:reply, result, state}
  end

  def handle_call({:set_event, event_name, value}, _from, state) do
    {:reply, :ok, %{state | events: Map.put(state.events, event_name, value)}}
  end

  @impl true
  def handle_info({:node_router_event, %{name: nil}}, state), do: {:noreply, state}

  def handle_info({:node_router_event, %{name: name} = event}, state) do
    event_key = to_string(name)

    case Map.get(state.events, event_key) do
      true ->
        state.fire_fn.(event_key, event)
        {:noreply, state}

      _ ->
        {:noreply, %{state | events: Map.put_new(state.events, event_key, false)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp load_trigger_state do
    Workflows.list_trigger_event_names()
    |> Enum.into(%{}, &{&1, true})
  end

  defp maybe_filter(events, nil), do: events
  defp maybe_filter(events, filter), do: Enum.filter(events, &(&1.is_trigger == filter))
end
