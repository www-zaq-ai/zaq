# Workflow Trigger System: Event-Driven Redesign

## Goal

Replace the current trigger system (Behaviour/Executor/Type modules) with a loose,
event-driven architecture built on NodeRouter + PubSub + a new Engine process.

---

## Architecture

```
Any caller
  └─► NodeRouter.dispatch(event)
         │
         ├─► Route to target role API (unchanged)
         │
         └─► Phoenix.PubSub.broadcast("node_router:events", event)   ← NEW side-channel
                        │
                        ▼
              Engine.EventRegistry  (GenServer, started by Engine.Supervisor)
                state: %{event_name :: atom => is_trigger :: boolean}
                init: load triggers table → set event_name entries to true
                handle_info: if state[event.name] == true
                               → Engine.TriggerNode.fire(event.name, event)
                             else
                               → store as false (seen, not a trigger)
                        │
                        ▼
              Engine.TriggerNode   (stateless module)
                - query triggers where event_name == name and enabled == true
                - preload :workflows (active only)
                - Task.async_stream → Workflows.create_run + start_run per workflow

Manual trigger path:
  BO → NodeRouter.dispatch(%Event{name: :manual_trigger, dest: :engine, action: :noop})
       └─► Engine.Api handles :noop (returns event unchanged)
       └─► PubSub broadcasts → EventRegistry → TriggerNode.fire(:manual_trigger, event)
```

---

## What Gets Deleted

All old trigger firing infrastructure. Keep only the Trigger schema (simplified).

| File | Action |
|---|---|
| `lib/zaq/engine/workflows/triggers/behaviour.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/executor.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/chain.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/workflow.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/type/manual.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/type/webhook.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/type/scheduler.ex` | DELETE |
| `lib/zaq/engine/workflows/triggers/type/signal.ex` | DELETE |

---

## Data Model Changes

### Trigger schema (simplified)

```
triggers
  id           uuid PK
  event_name   string NOT NULL   ← NEW (atom stored as string, e.g. "manual_trigger")
  enabled      boolean default true
  inserted_at  utc_datetime
  updated_at   utc_datetime

trigger_workflows  (keep — links trigger to its workflows)
  trigger_id   uuid FK
  workflow_id  uuid FK
  position     integer default 0
```

Drop: `type`, `config`, `execution_mode`, `max_concurrency`, `on_failure` columns.
Drop: `trigger_chains` table (chain logic removed).

### Event struct

Add `name` atom field to `%Zaq.Event{}`:

```elixir
field :name, :atom, default: nil
```

NodeRouter broadcasts the event on every dispatch. The EventRegistry uses `event.name`
as the lookup key. Events without a name (nil) are ignored by the registry.

---

## Implementation Steps

### Step 1 — Migration

**File**: `priv/repo/migrations/20260517000001_simplify_triggers.exs`

```elixir
alter table(:triggers) do
  add :event_name, :string, null: false, default: ""
  remove :type
  remove :config
  remove :execution_mode
  remove :max_concurrency
  remove :on_failure
end

drop table(:trigger_chains)
```

Indexes: add `create index(:triggers, [:event_name])`.

---

### Step 2 — Add `name` field to `%Zaq.Event{}`

**File**: `lib/zaq/event.ex`

Add `field :name, atom, default: nil` (or a plain map key if Event is not an Ecto schema —
check the struct definition and use the correct pattern).

`Event.new/3` should accept `:name` in opts or as a top-level key in the request map.

---

### Step 3 — NodeRouter PubSub side-channel

**File**: `lib/zaq/node_router.ex`

In `do_dispatch/1` (both sync and async paths), after the target role API handles the
event, broadcast to PubSub:

```elixir
@pubsub Zaq.PubSub
@trigger_topic "node_router:events"

defp maybe_broadcast(%Event{name: nil} = event), do: event
defp maybe_broadcast(%Event{} = event) do
  Phoenix.PubSub.broadcast(@pubsub, @trigger_topic, {:node_router_event, event})
  event
end
```

Call `maybe_broadcast/1` at the end of `do_dispatch_sync/1` before returning.

For async dispatch, broadcast inside the async task after the sync call completes.

---

### Step 4 — Simplify Trigger schema

**File**: `lib/zaq/engine/workflows/triggers/trigger.ex`

```elixir
schema "triggers" do
  field :event_name, :string
  field :enabled, :boolean, default: true

  many_to_many :workflows, Workflow,
    join_through: "trigger_workflows",
    join_keys: [trigger_id: :id, workflow_id: :id]

  timestamps(type: :utc_datetime)
end

def changeset(trigger, attrs) do
  trigger
  |> cast(attrs, [:event_name, :enabled])
  |> validate_required([:event_name])
end
```

Remove all aliases for Chain, TriggerWorkflow (join schema), type modules, Behaviour.
Update `@moduledoc` to describe the new event-driven model.

---

### Step 5 — Engine.EventRegistry (GenServer)

**File**: `lib/zaq/engine/event_registry.ex`

```elixir
defmodule Zaq.Engine.EventRegistry do
  @moduledoc """
  Subscribes to all events dispatched via NodeRouter and fires triggers
  when a known trigger event name passes through.

  State: %{event_name_string => boolean}
    true  — this event name is a configured trigger
    false — event was seen but is not a trigger
  """

  use GenServer

  alias Zaq.Engine.{TriggerNode, Workflows}

  @pubsub Zaq.PubSub
  @topic "node_router:events"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
    state = load_trigger_state()
    {:ok, state}
  end

  @impl true
  def handle_info({:node_router_event, %{name: nil}}, state), do: {:noreply, state}

  def handle_info({:node_router_event, %{name: name} = event}, state) do
    event_key = to_string(name)

    case Map.get(state, event_key) do
      true ->
        TriggerNode.fire(event_key, event)
        {:noreply, state}

      _ ->
        {:noreply, Map.put_new(state, event_key, false)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Loads all enabled trigger event_names from the DB and marks them true.
  defp load_trigger_state do
    Workflows.list_trigger_event_names()
    |> Enum.into(%{}, &{&1, true})
  end
end
```

---

### Step 6 — Engine.TriggerNode

**File**: `lib/zaq/engine/trigger_node.ex`

```elixir
defmodule Zaq.Engine.TriggerNode do
  @moduledoc """
  Fires all workflows associated with a trigger event_name, in parallel.
  """

  alias Zaq.Engine.Workflows

  @spec fire(String.t(), map()) :: :ok
  def fire(event_name, _event) do
    event_name
    |> Workflows.list_workflows_for_trigger()
    |> Task.async_stream(&run_workflow/1, ordered: false)
    |> Stream.run()

    :ok
  end

  defp run_workflow(workflow) do
    with {:ok, run} <- Workflows.create_run(workflow, build_event(workflow)),
         {:ok, _} <- Workflows.start_run(run) do
      :ok
    end
  end

  defp build_event(workflow) do
    %Zaq.Event{
      trace_id: Ecto.UUID.generate(),
      assigns: %{trigger_type: :event, workflow_id: workflow.id}
    }
  end
end
```

---

### Step 7 — Update Workflows context API

**File**: `lib/zaq/engine/workflows.ex`

Add:
- `list_trigger_event_names/0` — returns `[String.t()]` of all enabled trigger `event_name` values
- `list_workflows_for_trigger/1` — takes `event_name` string, returns `[Workflow.t()]` (active only, preloaded via trigger_workflows)

Remove/update:
- `list_triggers/2` — remove `workflow_id` param; list all triggers
- `create_trigger/2` — accept `event_name` instead of `type`/`config`
- Remove: `run_workflow_manually/3` (replaced by manual trigger event dispatch)
- Remove aliases for `Chain`, `Manual`, `TriggerWorkflow` (old modules)

---

### Step 8 — Engine.Api: handle `:noop` action

**File**: `lib/zaq/engine/api.ex`

Add a clause for `:noop` action that returns the event unchanged:

```elixir
def handle_event(event, :noop, _conn), do: event
```

---

### Step 9 — Engine.Supervisor: add EventRegistry

**File**: `lib/zaq/engine/supervisor.ex`

Add `Zaq.Engine.EventRegistry` to the children list:

```elixir
children = [
  Zaq.Engine.Telemetry.Supervisor,
  Zaq.Engine.IngestionSupervisor,
  Zaq.Engine.RetrievalSupervisor,
  Zaq.Engine.EventRegistry          # ← NEW
]
```

---

### Step 10 — BO manual trigger dispatch

**File**: wherever the BO "Run Workflow" button handler lives (LiveView or controller)

Replace the old `Manual.fire_for_workflow/2` call with:

```elixir
event = Zaq.Event.new(%{name: :manual_trigger}, :engine, opts: [action: :noop])
Zaq.NodeRouter.dispatch(event)
```

The event flows: NodeRouter → Engine.Api (:noop, returns immediately) → PubSub broadcast
→ EventRegistry → TriggerNode.fire("manual_trigger", event) → all workflows linked to
the `manual_trigger` trigger record get a run created and started.

---

### Step 11 — Tests

**Files to write tests for (TDD — write tests first):**

- `test/zaq/engine/event_registry_test.exs`
  - starts with trigger state loaded from DB
  - ignores events with `name: nil`
  - fires TriggerNode when a known trigger event arrives
  - adds unseen events to state as false
  - does not re-trigger on false events

- `test/zaq/engine/trigger_node_test.exs`
  - `fire/2` creates and starts runs for all workflows linked to trigger
  - handles empty workflow list gracefully
  - runs in parallel (Task.async_stream)

- `test/zaq/engine/workflows/triggers/trigger_test.exs` (update existing)
  - remove all old type-specific tests
  - changeset requires event_name
  - changeset rejects blank event_name

- `test/zaq/node_router_test.exs` (update existing)
  - every dispatch broadcasts to "node_router:events" PubSub topic
  - events with nil name broadcast but are skipped by registry

---

## Invariants

- NodeRouter broadcast is fire-and-forget — never blocks the dispatch result
- EventRegistry fires TriggerNode asynchronously — never blocks the PubSub handler
- TriggerNode failures do not crash EventRegistry (Task.async_stream with no await on crash)
- Workflows with `status != "active"` are excluded from `list_workflows_for_trigger/1`

---

## Files Summary

| Action | File |
|---|---|
| NEW | `lib/zaq/engine/event_registry.ex` |
| NEW | `lib/zaq/engine/trigger_node.ex` |
| NEW | `priv/repo/migrations/20260517000001_simplify_triggers.exs` |
| MODIFY | `lib/zaq/event.ex` — add `name` field |
| MODIFY | `lib/zaq/node_router.ex` — PubSub broadcast side-channel |
| MODIFY | `lib/zaq/engine/supervisor.ex` — add EventRegistry child |
| MODIFY | `lib/zaq/engine/api.ex` — handle `:noop` action |
| MODIFY | `lib/zaq/engine/workflows/triggers/trigger.ex` — simplify schema |
| MODIFY | `lib/zaq/engine/workflows.ex` — update context API |
| MODIFY | BO LiveView — replace manual trigger call |
| DELETE | `lib/zaq/engine/workflows/triggers/behaviour.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/executor.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/chain.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/workflow.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/type/manual.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/type/webhook.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/type/scheduler.ex` |
| DELETE | `lib/zaq/engine/workflows/triggers/type/signal.ex` |
