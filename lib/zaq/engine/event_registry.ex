defmodule Zaq.Engine.EventRegistry do
  @moduledoc """
  Subscribes to all events dispatched via NodeRouter and fires triggers
  when a known trigger event name passes through.

  State: a map with two keys:
  - `:events`   — `%{event_name_string => boolean}` (true = known trigger, false = seen but not a trigger)
  - `:fire_fn`  — `(event_name, event -> :ok)` — defaults to `TriggerNode.fire/2`,
                   injectable via `opts` for tests.

  Shortly after init (via `handle_continue`), loads all enabled trigger
  `event_name` values from the DB and marks them `true` in the `:events` map.
  A DB failure during this load degrades to an empty registry rather than
  crashing the process. On each incoming event:
  - The event key is `"destination:name"` — destination from `event.next_hop.destination`,
    name from `event.name` if set, otherwise `event.opts[:action]`
  - If neither name nor action is set → ignored
  - If `events[event_key] == true` → delegates to `fire_fn`
  - Otherwise → stores the event key as `false`
  """

  use GenServer

  require Logger

  alias Zaq.Engine.{TriggerNode, Workflows}

  @pubsub Zaq.PubSub
  @topic "node_router:events"

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Returns all known events as `%{event_name => boolean}`. Optionally filter with `is_trigger: true | false`."
  @spec list_events(keyword(), GenServer.server()) :: %{String.t() => boolean()}
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
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    fire_fn = Keyword.get(opts, :trigger_node_fn, &TriggerNode.fire/2)
    {:ok, %{events: %{}, fire_fn: fire_fn}, {:continue, :load_triggers}}
  end

  # Trigger state is loaded after init returns so a DB failure (e.g. a
  # supervisor restart while the test sandbox is in :manual mode) degrades
  # to an empty registry instead of crash-looping and taking down the repo.
  @impl true
  def handle_continue(:load_triggers, state) do
    events =
      try do
        load_trigger_state()
      rescue
        error ->
          Logger.warning(
            "EventRegistry: failed to load trigger state on startup: " <>
              Exception.message(error)
          )

          state.events
      end

    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_call({:list_events, opts}, _from, state) do
    {:reply, maybe_filter(state.events, opts[:is_trigger]), state}
  end

  def handle_call({:set_event, event_name, value}, _from, state) do
    {:reply, :ok, %{state | events: Map.put(state.events, event_name, value)}}
  end

  @impl true
  def handle_info({:node_router_event, event}, state) do
    event_key = derive_event_key(event)

    Logger.debug(
      "[event_registry] event received event_name=#{inspect(event.name)} event_key=#{inspect(event_key)} known_triggers=#{inspect(Map.keys(state.events))}"
    )

    case event_key do
      nil ->
        Logger.debug(
          "[event_registry] event ignored — could not derive key event_name=#{inspect(event.name)}"
        )

        {:noreply, state}

      key ->
        {:noreply, fire_or_register(key, event, state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fire_or_register(event_key, event, state) do
    case Map.get(state.events, event_key) do
      true ->
        Logger.info("[event_registry] trigger fired event_key=#{event_key}")

        Task.Supervisor.start_child(Zaq.TaskSupervisor, fn -> state.fire_fn.(event_key, event) end)

        state

      false ->
        Logger.debug("[event_registry] event seen but not a trigger event_key=#{event_key}")
        state

      nil ->
        Logger.debug(
          "[event_registry] event not in registry — registering as non-trigger event_key=#{event_key}"
        )

        %{state | events: Map.put_new(state.events, event_key, false)}
    end
  end

  defp derive_event_key(event) do
    case {derive_destination(event), derive_base_name(event)} do
      {destination, base} when is_atom(destination) and is_binary(base) ->
        maybe_prefix_destination(base, destination)

      _ ->
        nil
    end
  end

  defp derive_base_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp derive_base_name(%{name: name}) when is_atom(name) and not is_nil(name),
    do: Atom.to_string(name)

  defp derive_base_name(%{opts: opts}) when is_list(opts) do
    case Keyword.get(opts, :action) do
      nil -> nil
      action -> Atom.to_string(action)
    end
  end

  defp derive_base_name(_), do: nil

  defp load_trigger_state do
    Workflows.list_trigger_event_names()
    |> Enum.into(%{}, &{&1, true})
  end

  defp derive_destination(%{next_hop: %{destination: destination}}) when is_atom(destination),
    do: destination

  defp derive_destination(%{hops: hops}) when is_list(hops) do
    case List.last(hops) do
      %{destination: destination} when is_atom(destination) -> destination
      _ -> nil
    end
  end

  defp derive_destination(_), do: nil

  defp maybe_prefix_destination(base, destination)
       when is_binary(base) and is_atom(destination) do
    if String.contains?(base, ":") do
      base
    else
      "#{destination}:#{base}"
    end
  end

  defp maybe_filter(events, nil), do: events
  defp maybe_filter(events, filter), do: Map.filter(events, fn {_k, v} -> v == filter end)
end
