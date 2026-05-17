# EventRegistry CRUD State Operations

## Goal

Add observable and mutable state operations to `Engine.EventRegistry` so that:
1. Callers can list all known events, optionally filtered by whether they are triggers.
2. When a trigger is deactivated (`enabled: false`), the registry state is updated
   immediately so that event stops firing workflows — without requiring a restart.

---

## New Public API

All three functions are synchronous `GenServer.call` or cast backed by the named
`EventRegistry` process (the singleton started by `Engine.Supervisor`).

```elixir
# Returns all known events as a list of maps, optionally filtered.
# opts: [is_trigger: true | false]
@spec list_events(keyword()) :: [%{name: String.t(), is_trigger: boolean()}]
EventRegistry.list_events()                    # all events
EventRegistry.list_events(is_trigger: true)    # only trigger events
EventRegistry.list_events(is_trigger: false)   # only non-trigger events

# Marks an event_name as false (disabled) in the registry state.
# Called when a trigger's enabled flag is set to false.
@spec deactivate(String.t()) :: :ok
EventRegistry.deactivate("invoice_created")

# Marks an event_name as true (enabled) in the registry state.
# Called when a trigger's enabled flag is set back to true.
@spec activate(String.t()) :: :ok
EventRegistry.activate("invoice_created")
```

---

## Integration: Workflows context → EventRegistry

`Workflows.update_trigger/3` is the canonical place where `enabled` changes.
After a successful DB update, call the registry synchronously:

```elixir
def update_trigger(%Trigger{} = trigger, attrs, _opts \\ []) do
  with {:ok, updated} <- trigger |> Trigger.changeset(attrs) |> Repo.update() do
    sync_registry(updated)
    {:ok, updated}
  end
end

defp sync_registry(%Trigger{event_name: name, enabled: true}),
  do: EventRegistry.activate(name)

defp sync_registry(%Trigger{event_name: name, enabled: false}),
  do: EventRegistry.deactivate(name)
```

This keeps coupling minimal — Workflows already owns the DB; the call to the
registry is a single line, analogous to a PubSub broadcast but synchronous so
the caller knows the state is consistent before returning.

---

## Implementation Steps

### Step 1 — `handle_call` clauses in EventRegistry

**File**: `lib/zaq/engine/event_registry.ex`

Add three public functions and their corresponding `handle_call`/`handle_cast` callbacks:

```elixir
# Public API

def list_events(opts \\ []) do
  GenServer.call(name(), {:list_events, opts})
end

def deactivate(event_name) when is_binary(event_name) do
  GenServer.call(name(), {:set_event, event_name, false})
end

def activate(event_name) when is_binary(event_name) do
  GenServer.call(name(), {:set_event, event_name, true})
end

defp name, do: __MODULE__

# Callbacks

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

defp maybe_filter(events, nil), do: events
defp maybe_filter(events, filter), do: Enum.filter(events, &(&1.is_trigger == filter))
```

The `name()` helper uses the registered name. For testability, tests already start
the registry with a unique name via opts — `list_events/1`, `deactivate/1`, and
`activate/1` must accept an optional `server` argument or use the registered name.

**Testability adjustment**: wrap the server target so tests can pass their pid:

```elixir
def list_events(opts \\ [], server \\ __MODULE__)
def deactivate(event_name, server \\ __MODULE__)
def activate(event_name, server \\ __MODULE__)
```

Then `GenServer.call(server, ...)` instead of `GenServer.call(__MODULE__, ...)`.

---

### Step 2 — Integrate into Workflows.update_trigger/3

**File**: `lib/zaq/engine/workflows.ex`

After the successful `Repo.update` in `update_trigger/3`, add a `sync_registry/1`
call as described above. Guard it with a check that the process is running (so
tests that only start the Workflows context without the full supervision tree
don't crash):

```elixir
defp sync_registry(%Trigger{event_name: name, enabled: true}) do
  if Process.whereis(EventRegistry), do: EventRegistry.activate(name)
  :ok
end

defp sync_registry(%Trigger{event_name: name, enabled: false}) do
  if Process.whereis(EventRegistry), do: EventRegistry.deactivate(name)
  :ok
end
```

---

## Tests (TDD order — write red first)

### `test/zaq/engine/event_registry_test.exs` — new describe blocks

```
describe "list_events/2" do
  - returns empty list when no events seen or loaded
  - returns all events when no filter given
  - returns only trigger events with is_trigger: true filter
  - returns only non-trigger events with is_trigger: false filter
  - returns correct is_trigger values (true for DB-loaded, false for seen-not-trigger)
end

describe "deactivate/2" do
  - sets a true event to false in state
  - deactivating an unknown event stores it as false
  - after deactivation, subsequent node_router_event does NOT fire TriggerNode
end

describe "activate/2" do
  - sets a false event to true in state
  - after activation, subsequent node_router_event DOES fire TriggerNode
  - activating an already-true event is a no-op (stays true)
end
```

### `test/zaq/engine/workflows_test.exs` — add to existing

```
describe "update_trigger/3 — registry sync" do
  - disabling a trigger calls EventRegistry.deactivate with event_name
  - enabling a trigger calls EventRegistry.activate with event_name
  - registry sync is skipped when EventRegistry process is not running
end
```

---

## Files Changed

| Action | File |
|---|---|
| MODIFY | `lib/zaq/engine/event_registry.ex` — add `list_events/2`, `deactivate/2`, `activate/2` public API + handle_call callbacks |
| MODIFY | `lib/zaq/engine/workflows.ex` — add `sync_registry/1` call in `update_trigger/3` |
| MODIFY | `test/zaq/engine/event_registry_test.exs` — new describe blocks |
| MODIFY | `test/zaq/engine/workflows_test.exs` — registry sync tests |

---

## Event.new/3 Compliance (fix alongside this work)

`Event.new(request, destination, opts)` is the only sanctioned way to build an
`%Event{}`. Two places currently bypass it with raw struct literals — both must
be fixed as part of this work.

### 1. `Engine.TriggerNode.build_event/1`

Current (wrong):
```elixir
defp build_event(workflow) do
  %Event{
    trace_id: Ecto.UUID.generate(),
    assigns: %{trigger_type: :event, workflow_id: workflow.id}
  }
end
```

Fix — use `Event.new/3`. The source event isn't routed further, but `:engine`
is the correct logical origin since TriggerNode runs inside the engine:
```elixir
defp build_event(workflow) do
  Event.new(
    %{trigger_type: :event, workflow_id: workflow.id},
    :engine,
    name: :workflow_run_triggered
  )
end
```

### 2. Test helper `build_event/1` in `EventRegistryTest`

Current (wrong):
```elixir
defp build_event(name) do
  %Event{request: %{}, next_hop: nil, name: name, trace_id: Ecto.UUID.generate()}
end
```

Fix:
```elixir
defp build_event(name) do
  Event.new(%{}, :engine, name: name)
end
```

`Event.new/3` auto-generates `trace_id` and sets `next_hop` via `EventHop.new/3`.
The EventRegistry only reads `event.name`, so the routing fields are irrelevant
for these tests.

### Where `Event.new/3` is already used correctly
- `NodeRouter` tests that build events for dispatch
- BO manual trigger dispatch (`Event.new(%{}, :engine, name: :manual_trigger, opts: [action: :noop])`)

---

## Invariants

- `deactivate/activate` are synchronous — caller is guaranteed state is updated before returning
- `list_events` never hits the DB — it reflects in-memory state only
- `sync_registry` is guarded by `Process.whereis` — safe to call from Workflows tests
  that run without the Engine supervision tree
- `deactivate` on an unknown event name is valid (stores it as false, preventing future
  accidental activation if an event with that name arrives later)
