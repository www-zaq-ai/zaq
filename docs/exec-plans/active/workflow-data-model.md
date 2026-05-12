# Execution Plan: Workflow Data Model — DB-Runnable Workflows

**Goal:** Make any automation workflow runnable from the database — general-purpose,
not email-specific. Users define a DAG of Jido actions, agents, and conditions
stored in `Workflow.steps`. The runtime reads that definition, builds a Runic DAG,
and executes it, writing `WorkflowRun` + `ActionResult` rows as it goes.

**Reference:** GH#256 (Workflow Architecture), GH#244 (Data model), GH#245 (WorkflowAgent)

**Out of scope for this plan:** `WorkflowAgent` execution engine, BO UI builder,
PubSub live updates. Those come after this layer is solid.

---

## Infrastructure Audit

**Existing — keep as-is:**
- `Zaq.Workflows.Workflow` — `steps: :map`, `settings: :map`, `status` — no new columns needed
- `Zaq.Workflows.WorkflowRun` — all fields correct; `source_event: :map` needs typed loading (see Step 2)
- `Zaq.Workflows.ActionResult` — matches GH#256 spec exactly
- `Zaq.Workflows.Trigger` — Ecto schema is fine; execution behaviour is missing (Step 4)
- `Zaq.Workflows` context — all CRUD functions present; no changes needed until WorkflowAgent

**Gaps driving this plan:**
1. `Workflow.steps` has no defined format — can't be deserialized to a Runic DAG
2. Conditions are inline lambdas — not serializable
3. `source_event` loads as a raw map — spec requires a typed struct (`Zaq.Event`)
4. No DAG builder — nothing reads `steps_snapshot` and produces `Runic.Workflow`
5. `Trigger` has no behaviour — `fire/3` and `on_complete/2` are not defined

---

## Step 1 — Define the `steps` JSON format and condition modules

**Depends on:** nothing (greenfield)

### What this step delivers

A canonical, machine-readable format for `Workflow.steps` / `steps_snapshot`, plus
a convention for condition modules so conditions are serializable by name.

### Functional specifications

#### 1a. `steps` format

`Workflow.steps` is a JSONB map with two top-level keys:

```json
{
  "nodes": [
    {
      "name":   "fetch",
      "type":   "action",
      "module": "Zaq.Agent.Tools.Email.FetchEmails",
      "params": {},
      "index":  0
    },
    {
      "name":   "emails_found",
      "type":   "condition",
      "module": "Zaq.Workflows.Conditions.EmailsFound",
      "params": {},
      "index":  1
    }
  ],
  "edges": [
    { "from": "fetch",        "to": "emails_found" },
    { "from": "emails_found", "to": "draft",  "validate_ports": false }
  ]
}
```

- `type` values: `"action"` | `"condition"` | `"agent"`
- `"agent"` nodes reference a `ConfiguredAgent` by name via `params.agent_name`
- `"validate_ports": false` maps to `validate: :off` in `Workflow.add/3`
- Root node has no incoming edges (the DAG traversal starts there automatically)

#### 1b. `Zaq.Workflows.Step` behaviour

Defines the contract every condition module must implement:

```elixir
@callback call(fact :: map()) :: boolean()
@callback name() :: String.t()
@callback description() :: String.t()
@optional_callbacks [description: 0]
```

Action modules already implement `Jido.Action` (`run/2`). Condition modules implement
`Zaq.Workflows.Step` instead.

#### 1c. Convert inline conditions to modules

The two conditions in `EmailReplyWorkflowRunic.dag/0` become:

- `Zaq.Workflows.Conditions.EmailsFound` — `call(%{emails: e})`, returns `e != []`
- `Zaq.Workflows.Conditions.NoEmails` — `call(%{emails: e})`, returns `e == []`

These live under `lib/zaq/workflows/conditions/`.

#### 1d. `Workflow` changeset validates `steps` structure

`Workflow.changeset/2` validates that `steps` contains `"nodes"` and `"edges"` keys
when the workflow status transitions to `"active"`. Draft workflows may have empty steps.

### Files to create / modify

| File | Change |
|---|---|
| `lib/zaq/workflows/step.ex` | New — `Zaq.Workflows.Step` behaviour |
| `lib/zaq/workflows/conditions/emails_found.ex` | New — condition module |
| `lib/zaq/workflows/conditions/no_emails.ex` | New — condition module |
| `lib/zaq/workflows/workflow.ex` | Add `steps` structure validation to changeset |
| `lib/zaq/workflows/examples/email_reply_workflow_runic.ex` | Replace inline lambdas with module references |

### Tests to write before implementation

`test/zaq/workflows/step_test.exs`
- condition module satisfies `Zaq.Workflows.Step` behaviour
- `EmailsFound.call/1` returns true when list non-empty, false when empty
- `NoEmails.call/1` mirrors

`test/zaq/workflows/workflow_test.exs`
- changeset accepts valid `steps` map with nodes + edges
- changeset rejects `steps` missing `"nodes"` or `"edges"` when status is `"active"`
- changeset accepts empty `steps` when status is `"draft"`

### Branches validated
- valid steps map → changeset passes
- missing nodes key → validation error (active only)
- missing edges key → validation error (active only)
- draft with empty steps → allowed

### Mocking plan
None — pure data/changeset logic.

### Documentation to update
- `Workflow` `@moduledoc` — document the `steps` JSON format inline
- `Zaq.Workflows.Step` `@moduledoc` — full behaviour contract

---

## Step 2 — Typed loading of `source_event`

**Depends on:** Step 1 (no code dependency, but defines the event shape needed by Step 4)

### What this step delivers

`WorkflowRun.source_event` loads as a structured map that preserves `trace_id`,
`assigns`, `trigger_type`, and `input` — not a raw opaque blob. `Zaq.Event` is a
plain struct (not an Ecto embedded schema), so we use a custom Ecto type that
casts/loads the JSONB map to/from a `Zaq.Event`-compatible shape.

### Decision

`Zaq.Event` is a cross-node envelope and must not become an Ecto schema — that would
couple the routing layer to persistence. Instead:

- Create `Zaq.Types.WorkflowEvent` — a custom `Ecto.Type` that casts a map into a
  `Zaq.Event` struct on load and dumps it back to a plain map on insert.
- `WorkflowRun` uses `field :source_event, Zaq.Types.WorkflowEvent`.
- No migration — the DB column stays `:map` (JSONB).

### Functional specifications

`Zaq.Types.WorkflowEvent` implements `Ecto.Type`:
- `type/0` → `:map`
- `cast/1` — accepts a `%Zaq.Event{}` or a plain map with string/atom keys; returns `{:ok, %Zaq.Event{}}`
- `dump/1` — serializes `%Zaq.Event{}` to a plain map (drops non-serializable terms like PIDs)
- `load/1` — reconstructs `%Zaq.Event{}` from the stored map; `hops` loads as list of plain maps (not `EventHop` structs, which are not needed at read time)
- `equal?/2` — compares by `trace_id`

### Files to create / modify

| File | Change |
|---|---|
| `lib/zaq/types/workflow_event.ex` | New — `Zaq.Types.WorkflowEvent` Ecto type |
| `lib/zaq/workflows/workflow_run.ex` | Change `field :source_event, :map` → `field :source_event, Zaq.Types.WorkflowEvent` |

### Tests to write before implementation

`test/zaq/types/workflow_event_test.exs`
- `cast/1` from `%Zaq.Event{}` → `{:ok, %Zaq.Event{}}`
- `cast/1` from string-key map → `{:ok, %Zaq.Event{}}` with correct fields
- `cast/1` from invalid input → `:error`
- `dump/1` from `%Zaq.Event{}` → plain serializable map
- `load/1` round-trip: dump then load returns equivalent struct
- `trace_id` is preserved through round-trip

`test/zaq/workflows/workflow_run_test.exs`
- `WorkflowRun.changeset/2` accepts a `%Zaq.Event{}` for `source_event`
- loaded `WorkflowRun` has `source_event` as a `%Zaq.Event{}` struct (integration test against DB)

### Branches validated
- cast from struct
- cast from string-key map
- cast from nil → `:error`
- dump with `hops` list
- load with missing optional fields → defaults applied

### Mocking plan
None — pure type casting.

### Documentation to update
- `WorkflowRun` `@moduledoc` — note that `source_event` loads as `%Zaq.Event{}`

---

## Step 3 — DAG builder: `steps_snapshot` → `Runic.Workflow`

**Depends on:** Step 1 (format definition) and Step 2 (not hard dependency, but both must exist before WorkflowAgent uses this)

### What this step delivers

`Zaq.Workflows.DagBuilder` — reads the `steps` / `steps_snapshot` map (node/edge format from Step 1) and produces a `Runic.Workflow` struct ready for `Jido.Runic.Strategy`.

### Functional specifications

```elixir
@spec build(steps :: map()) :: {:ok, Runic.Workflow.t()} | {:error, term()}
def build(steps)
```

Internal logic:

1. Parse `nodes` list → build a name→node map
2. Parse `edges` list → build adjacency list
3. For each node (ordered by `index`):
   - `"action"` / `"agent"` → `Jido.Runic.ActionNode.new(module, params, name: name)`
   - `"condition"` → `Runic.condition(&module.call/1, name: name)` where `module` is resolved via `Module.safe_concat/1`
4. Start with `Runic.Workflow.new(workflow_name)`, then `Workflow.add/3` each edge
5. Return `{:ok, workflow}` or `{:error, reason}` (unknown module, acyclic violation, etc.)

Module resolution uses `Module.safe_concat(["Elixir" | parts])` — never `String.to_atom/1`.

### Files to create / modify

| File | Change |
|---|---|
| `lib/zaq/workflows/dag_builder.ex` | New — `Zaq.Workflows.DagBuilder` |

### Tests to write before implementation

`test/zaq/workflows/dag_builder_test.exs`
- builds a valid `Runic.Workflow` from a well-formed steps map
- returns `{:error, _}` for unknown module string
- returns `{:error, _}` for unknown node referenced in edges
- action nodes get correct params merged
- condition nodes resolve to the correct module's `call/1`
- `validate_ports: false` edges pass `validate: :off` to `Workflow.add/3`
- empty nodes/edges → `{:error, :empty_dag}`

### Branches validated
- action node → `ActionNode`
- condition node → `Runic.condition` with module ref
- edge with `validate_ports: false`
- edge without `validate_ports` (defaults to port validation on)
- unknown module → error
- cyclic graph → error (Runic validates this)

### Mocking plan
None — pure data transformation. Runic is a local dep.

### Documentation to update
- `DagBuilder` `@moduledoc` — document the expected input format with example

---

## Step 4 — `Trigger` behaviour: `fire/3` and `on_complete/2`

**Depends on:** Step 2 (`source_event` must be typed before `fire/3` constructs one)

### What this step delivers

`Zaq.Workflows.TriggerBehaviour` — the execution contract for all trigger types.
Four concrete trigger modules. The `Trigger` schema gains a derived `module/1` helper
that maps `type` string → module atom.

### Functional specifications

#### 4a. `Zaq.Workflows.TriggerBehaviour`

```elixir
@callback fire(trigger :: Trigger.t(), workflow :: Workflow.t(), input :: map()) ::
            {:ok, WorkflowRun.t()} | {:error, term()}

@callback on_complete(run :: WorkflowRun.t(), action_results :: [ActionResult.t()]) ::
            :ok | {:error, term()}
```

`fire/3` must:
1. Build a `%Zaq.Event{}` with `assigns.trigger_type` set
2. Call `Workflows.create_run(workflow, event, %{})` to insert the `WorkflowRun`
3. Return `{:ok, run}` — starting the `WorkflowAgent` is the caller's responsibility
   (keeps trigger stateless and testable)

`on_complete/2` dispatches the outgoing event via `NodeRouter.call/4` using the
`next_hop.destination` encoded in the original `source_event`.

#### 4b. Concrete trigger modules

| Module | Type string | `fire/3` behaviour |
|---|---|---|
| `Zaq.Workflows.Triggers.Manual` | `"manual"` | Input comes from caller, `assigns.trigger_type: :manual` |
| `Zaq.Workflows.Triggers.Webhook` | `"webhook"` | Input is the parsed JSON body |
| `Zaq.Workflows.Triggers.Scheduler` | `"scheduler"` | Input from `trigger.config["static_input"]`; called by Oban worker |
| `Zaq.Workflows.Triggers.Signal` | `"signal"` | Input from matching Jido signal payload |

#### 4c. `Trigger.module/1` helper

```elixir
@spec module(Trigger.t()) :: module()
def module(%Trigger{type: type})
```

Maps `"manual"` → `Zaq.Workflows.Triggers.Manual`, etc. Returns `{:error, :unknown_type}`
for unrecognised strings.

### Files to create / modify

| File | Change |
|---|---|
| `lib/zaq/workflows/trigger_behaviour.ex` | New — `Zaq.Workflows.TriggerBehaviour` |
| `lib/zaq/workflows/triggers/manual.ex` | New |
| `lib/zaq/workflows/triggers/webhook.ex` | New |
| `lib/zaq/workflows/triggers/scheduler.ex` | New |
| `lib/zaq/workflows/triggers/signal.ex` | New |
| `lib/zaq/workflows/trigger.ex` | Add `module/1` helper |

### Tests to write before implementation

`test/zaq/workflows/triggers/manual_test.exs`
- `fire/3` inserts a `WorkflowRun` with `status: "pending"`
- `fire/3` sets `source_event.assigns.trigger_type = :manual`
- `fire/3` returns `{:ok, %WorkflowRun{}}` with correct `workflow_id`
- `on_complete/2` — called with completed run returns `:ok`

`test/zaq/workflows/triggers/scheduler_test.exs`
- `fire/3` reads `static_input` from `trigger.config`
- `fire/3` inserts run with correct snapshot

`test/zaq/workflows/trigger_test.exs`
- `Trigger.module/1` maps all four type strings correctly
- `Trigger.module/1` returns error for unknown type

### Branches validated
- manual trigger with input → run created
- scheduler trigger with static_input → run created
- unknown type → `{:error, :unknown_type}`
- `on_complete` for each trigger type

### Mocking plan
- `on_complete/2` in `Scheduler` and `Signal` triggers stubs `NodeRouter.call/4`
  (it's a cross-node boundary). Use `Mox` mock for `NodeRouter` in those tests only.

### Documentation to update
- `TriggerBehaviour` `@moduledoc` — full contract with example
- `Trigger` `@moduledoc` — add note about `module/1` helper and type→module mapping

---

## Definition of Done

- [ ] All four steps implemented with tests passing
- [ ] `mix precommit` passes (Credo, Dialyzer, format)
- [ ] Coverage ≥ 95% for every new/modified file
- [ ] `EmailReplyWorkflowRunic.dag/0` uses condition modules from Step 1 (no inline lambdas)
- [ ] A `WorkflowRun` can be created from a `Workflow` row + a trigger fire, with `source_event` loading back as `%Zaq.Event{}`
- [ ] `DagBuilder.build/1` produces a runnable `Runic.Workflow` from the email reply workflow's `steps` map

## What this plan does NOT cover

- `WorkflowAgent` (GH#245) — reads these data models and executes them
- BO workflow builder UI (GH#248)
- Action/condition registry for the UI picker
- PubSub `workflow.run.*` events
