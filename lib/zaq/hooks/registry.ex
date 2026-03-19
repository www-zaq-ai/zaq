defmodule Zaq.Hooks.Registry do
  @moduledoc """
  Dynamic registry for ZAQ hook handlers.

  A GenServer owns the canonical state (`%{event => [Hook.t()]}` sorted by priority).
  An ETS table (`:set`, `:public`, `read_concurrency: true`) mirrors the state so that
  `lookup/1` is always a lock-free read — it never blocks on the GenServer.

  Writes (`register/1`, `unregister/1`) go through the GenServer to serialise mutations.

  ## ETS table naming

  The ETS table is created with the same name as the GenServer (default `__MODULE__`).
  This lets tests start an isolated registry under a unique name and swap it via:

      Application.put_env(:zaq, :hooks_registry_module, :my_test_registry)

  ## Example

      Zaq.Hooks.Registry.register(%Zaq.Hooks.Hook{
        handler:   MyAuditHook,
        events:    [:after_answer_generated],
        mode:      :async,
        node_role: :agent
      })

      Zaq.Hooks.Registry.lookup(:after_answer_generated)
      #=> [%Zaq.Hooks.Hook{handler: MyAuditHook, ...}]
  """

  use GenServer

  alias Zaq.Hooks.Hook

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @doc "Registers a hook for all events listed in `hook.events`."
  @spec register(Hook.t()) :: :ok
  def register(%Hook{} = hook) do
    GenServer.call(registry_name(), {:register, hook})
  end

  @doc "Removes all registrations for `handler` across all events."
  @spec unregister(module()) :: :ok
  def unregister(handler) when is_atom(handler) do
    GenServer.call(registry_name(), {:unregister, handler})
  end

  @doc "Returns hooks for `event`, sorted by priority. Lock-free ETS read."
  @spec lookup(atom()) :: [Hook.t()]
  def lookup(event) when is_atom(event) do
    table = registry_name()

    case :ets.lookup(table, event) do
      [{^event, hooks}] -> hooks
      [] -> []
    end
  rescue
    # Table doesn't exist (registry not started or stopped)
    ArgumentError -> []
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(table_name) do
    :ets.new(table_name, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{table: table_name, hooks: %{}}}
  end

  @impl true
  def handle_call({:register, %Hook{handler: handler, events: events} = hook}, _from, state) do
    hooks = state.hooks |> remove_handler(handler) |> add_hook(hook, events)
    sync_ets(state.table, hooks)
    {:reply, :ok, %{state | hooks: hooks}}
  end

  @impl true
  def handle_call({:unregister, handler}, _from, state) do
    hooks = remove_handler(state.hooks, handler)
    sync_ets(state.table, hooks)
    {:reply, :ok, %{state | hooks: hooks}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp registry_name do
    Application.get_env(:zaq, :hooks_registry_name, __MODULE__)
  end

  defp add_hook(hooks, hook, events) do
    Enum.reduce(events, hooks, fn event, acc ->
      existing = Map.get(acc, event, [])
      # Replace existing entry for this handler (no duplicates), then sort by priority
      updated =
        [hook | Enum.reject(existing, &(&1.handler == hook.handler))]
        |> Enum.sort_by(& &1.priority)

      Map.put(acc, event, updated)
    end)
  end

  defp remove_handler(hooks, handler) do
    Map.new(hooks, fn {event, hs} ->
      {event, Enum.reject(hs, &(&1.handler == handler))}
    end)
  end

  defp sync_ets(table, hooks) do
    :ets.delete_all_objects(table)

    Enum.each(hooks, fn {event, hs} ->
      :ets.insert(table, {event, hs})
    end)
  end
end
