# Hooks Service

## Overview

The Hooks service is ZAQ's internal event pipeline. It lets any module register
handlers that fire at named points in the agent pipeline, ingestion, and
conversation flows — without coupling producers to consumers.

Hooks are registered at startup (or dynamically at runtime) and dispatched
either synchronously (allowing payload mutation and halting) or asynchronously
(fire-and-forget observers).

The registry is started before all role-specific supervisors so hooks are
available on every node role.

---

## Architecture

```
Zaq.Hooks.Supervisor
  ├── Zaq.Hooks.Registry          (GenServer + ETS for lock-free reads)
  └── Zaq.DynamicSupervisor       (for async Task dispatch)
```

Writes (register/unregister) are serialised through the GenServer.
Reads (`lookup/1`) are lock-free ETS reads — no GenServer round-trip.

Async hooks with a `node_role` other than `:local` are dispatched via
`NodeRouter`. Async hooks with `node_role: :local` spawn a `Task`.

---

## Key Modules

### `Zaq.Hooks` — public dispatch API

The top-level module used by pipeline producers (e.g. `Zaq.Agent.Pipeline`).

```elixir
@spec dispatch_before(atom(), map(), map()) :: {:ok, map()} | {:halt, map()}
@spec dispatch_after(atom(), map(), map()) :: :ok
```

- `dispatch_before/3` — runs all `:sync` hooks for `event` in priority order, threading `payload` through the chain. Returns `{:ok, payload}` or `{:halt, payload}`.
- `dispatch_after/3` — dispatches `event` to all hooks. Sync hooks run in-process (return value ignored). Async hooks are spawned in Tasks. Always returns `:ok`.

Both functions emit Telemetry events:

```
[:zaq, :hooks, :dispatch, :start]   metadata: %{event, mode, hook_count}
[:zaq, :hooks, :dispatch, :stop]    measurements: %{duration}, metadata: %{event, mode}
[:zaq, :hooks, :handler, :error]    metadata: %{event, handler, reason}
```

Errors in any handler are caught and logged — they never propagate to the caller.

Injectable for tests:

```elixir
Application.put_env(:zaq, :hooks_registry_module, MyMockRegistry)
Application.put_env(:zaq, :hooks_node_router_module, MyMockRouter)
```

### `Zaq.Hooks.Hook` — struct

Represents a registered hook. Fields:

| Field | Type | Default | Description |
|---|---|---|---|
| `:handler` | `module()` | required | Module implementing `Zaq.Hooks.Handler` |
| `:events` | `[atom()]` | required | Events this hook subscribes to |
| `:mode` | `:sync \| :async` | required | Sync mutates payload; async is fire-and-forget |
| `:node_role` | atom | `:local` | Target role for async dispatch; `:local` spawns a Task |
| `:priority` | `non_neg_integer()` | `50` | Lower runs first; only meaningful for `:before_*` sync hooks |

### `Zaq.Hooks.Registry` — GenServer + ETS

Dynamic registry. State is `%{event => [Hook.t()]}` sorted by priority,
mirrored into an ETS table for lock-free reads.

Public API:

```elixir
@spec register(Hook.t()) :: :ok
@spec unregister(module()) :: :ok
@spec lookup(atom()) :: [Hook.t()]
```

- `register/1` — registers a hook for all events in `hook.events`; replaces
  any existing registration for the same handler (no duplicates)
- `unregister/1` — removes all registrations for a handler across all events
- `lookup/1` — lock-free ETS read; returns `[]` if the registry is not running

The registry name is configurable via:

```elixir
Application.put_env(:zaq, :hooks_registry_name, :my_test_registry)
```

### `Zaq.Hooks.Handler` — behaviour

Every hook handler must implement:

```elixir
@callback handle(event(), payload(), context()) ::
  {:ok, payload()}    # continue with (possibly mutated) payload
  | {:halt, payload()} # stop chain; dispatch_before returns {:halt, payload}
  | {:error, term()}   # skip this handler, log warning, continue chain
  | :ok                # observer acknowledgement (async/after hooks)
```

### `Zaq.Hooks.Supervisor`

Started as a base application child before role-specific supervisors.
Starts `Zaq.Hooks.Registry` and `Zaq.DynamicSupervisor`.

---

## Hook Events

### Agent Pipeline (`Zaq.Agent.Pipeline`)

Context for all agent events: `%{trace_id: String.t(), node: node()}`

| Event | Mode | Payload fields |
|---|---|---|
| `:before_retrieval` | sync (mutatable) | `%{question: String.t()}` |
| `:after_retrieval` | async (observer) | `%{query, language, positive_answer, negative_answer}` |
| `:before_answering` | sync (mutatable) | `%{query, language, positive_answer, negative_answer}` |
| `:after_answer_generated` | async (observer) | `%{answer: %Zaq.Agent.Answering.Result{}}` |
| `:after_pipeline_complete` | async (observer) | `%{answer, confidence_score, latency_ms, prompt_tokens, completion_tokens, total_tokens, error, chunks}` |

`chunks` is `[]` when the pipeline produced no retrieval results.

### Ingestion (`Zaq.Ingestion.Chunk`)

Context: `%{}`

| Event | Mode | Payload fields |
|---|---|---|
| `:after_embedding_reset` | async (observer) | `%{new_dimension: integer()}` |

Fired after `Chunk.reset_table/1` drops and recreates the chunks table with a
new embedding dimension. Features maintaining their own embedding columns should
listen to this event to reset and re-embed their data.

### Conversations (`Zaq.Engine.Conversations`)

Context: `%{}`

| Event | Mode | Payload fields |
|---|---|---|
| `:feedback_provided` | async (observer) | `%{message, rating, conversation_history, rater_attrs}` |

Fired after a message rating is created or updated. `conversation_history`
always contains all messages in the conversation ordered by insertion time.

---

## Registering a Hook

```elixir
Zaq.Hooks.Registry.register(%Zaq.Hooks.Hook{
  handler:   MyAuditHook,
  events:    [:after_pipeline_complete],
  mode:      :async,
  node_role: :agent
})
```

The handler module must implement `Zaq.Hooks.Handler`:

```elixir
defmodule MyAuditHook do
  @behaviour Zaq.Hooks.Handler

  @impl true
  def handle(:after_pipeline_complete, payload, _context) do
    # fire-and-forget observer
    :ok
  end
end
```

---

## Files

```
lib/zaq/hooks.ex        # Public dispatch API: dispatch_before/3, dispatch_after/3
lib/zaq/hooks/
├── hook.ex             # Hook struct and type
├── registry.ex         # GenServer + ETS registry (register/unregister/lookup)
├── handler.ex          # Behaviour contract + full event catalogue with payload shapes
└── supervisor.ex       # Starts Registry and DynamicSupervisor
```
