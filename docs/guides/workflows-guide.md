# Authoring ZAQ Workflows — A Practical Guide

This is a **human-facing how-to** for building workflows: what the pieces are,
how data flows between them, and copy-pasteable examples. For the engine
internals (run lifecycle, schemas, DAG building) see
[`docs/services/workflows.md`](../services/workflows.md).

---

## 1. The mental model

A workflow is a **directed graph (DAG)**:

- **Nodes** = the *steps* that do work (run an agent, check a condition, write a
  file, …).
- **Edges** = the connections between steps. An edge can carry a **condition**
  (should we follow this path?) and a **mapping** (what data does the next step
  receive?).

A workflow is stored as a plain map (persisted as JSONB) with two keys —
`nodes` and `edges` — plus some metadata:

```elixir
%{
  name: "My Workflow",
  status: "active",
  nodes: [ ... ],
  edges: [ ... ]
}
```

At run time the engine builds this map into an executable graph and walks it,
running each node and recording a result row per step.

> **Keys:** node/edge maps use **string keys** for their *contents*
> (`"name"`, `"params"`, `"conditions"`, …). The top-level `nodes:`/`edges:`
> and the `from:`/`to:`/`condition:`/`mapping:` edge fields are read with both
> atom and string keys, so the examples here that use atoms on edges are valid.
> When in doubt, prefer strings.

---

## 2. Anatomy of a node (step)

Every node has the same shape:

```elixir
%{
  "name"   => "draft_email",                         # unique within the workflow
  "type"   => "action",                              # see node types below
  "module" => "Zaq.Agent.Tools.Workflow.RunAgent",   # which code runs (action/agent/map nodes)
  "params" => %{"agent_id" => 42, "input" => "..."}, # static inputs for this step
  "index"  => 2                                       # ordering hint
}
```

### Node types

| `type`     | What it is                                                                 |
|------------|---------------------------------------------------------------------------|
| `action`   | Runs an **Action** module (a tool). The workhorse. See §3.                 |
| `agent`    | Like `action`, but the module is an agent-style tool (same contract).      |
| `map`      | Fan-out: runs an inner `body` of nodes once per item in a collection.      |
| `batch`    | Build-time helper that lowers into a `map` node.                           |
| `workflow` | Embeds another workflow inline (composition).                             |

The **Condition node** (§4) and **Human-in-the-loop** (§5) are *also* `action`
nodes — they're just specific modules. There is no special `"condition"` type.

---

## 3. Actions

An **Action** is the unit of work. Technically it's a `Jido.Action` that also
satisfies the `Zaq.Engine.Workflows.Action` contract. You rarely write one from
scratch — you reference an existing tool by its module name in a node.

What makes a module a valid workflow action:

- a non-empty **`schema`** — its accepted inputs (with types/required/defaults),
- a non-empty **`output_schema`** — what it returns,
- `on_success/2` and `on_failure/2` (provided for free by
  `use Zaq.Engine.Workflows.Action`).

The DAG build **refuses** a node whose module doesn't conform
(`{:error, {:contract_violation, module, missing}}`), so a typo'd module or a
non-action module fails fast.

### How an action gets its inputs

Two sources merge into the params an action's `run/2` receives:

1. **Static `params`** declared on the node.
2. **Mapped data** delivered by incoming edges (§6) — plus accumulated values
   from upstream steps.

So a node's `"input"` can be a template that pulls from mapped data:

```elixir
%{
  "name"   => "draft_email",
  "type"   => "action",
  "module" => "Zaq.Agent.Tools.Workflow.RunAgent",
  "params" => %{
    "agent_id" => 42,
    # {{name}} / {{company}} are filled from accumulated workflow params
    "input"    => "Draft an outreach email for {{name}} at {{company}}."
  },
  "index"  => 0
}
```

### A few ready-made actions

| Module                                         | Does                                                        |
|------------------------------------------------|------------------------------------------------------------|
| `Zaq.Agent.Tools.Workflow.RunAgent`            | Runs a configured agent (`agent_id` + `input`).            |
| `Zaq.Agent.Tools.Workflow.Condition`           | Branch on field conditions (§4).                           |
| `Zaq.Agent.Tools.Workflow.Increment`           | Increment an integer by 1.                                 |
| `Zaq.Agent.Tools.Workflow.Concat`              | Concatenate parts into a string / matrix.                  |
| `Zaq.Agent.Tools.Workflow.DispatchEvent`       | Emit a `Zaq.Event` (e.g. trigger another workflow).        |
| `Zaq.Agent.Tools.Workflow.Sleep`               | Pause for `duration_ms`.                                   |
| `Zaq.Agent.Tools.DataSource.CreateDocument`    | Create a file (or folder, via folder `mime_type`).         |

> **Tip — folders are files.** `CreateDocument` creates a folder when you pass
> `"mime_type" => "application/vnd.google-apps.folder"`. There is no separate
> "create folder" action.

---

## 4. The Condition node

`Zaq.Agent.Tools.Workflow.Condition` checks that **all** of a list of conditions
hold on an input map, then reports the outcome as a `passed` boolean. Use it to
branch inside the graph (combine it with edge conditions in §6).

```elixir
%{
  "name"   => "check_lead",
  "type"   => "action",
  "module" => "Zaq.Agent.Tools.Workflow.Condition",
  "params" => %{
    "input"      => "{{row}}",            # the map to evaluate (often mapped in)
    "conditions" => [
      %{"key" => "active",   "value" => true},               # op defaults to "eq"
      %{"key" => "sequence", "op" => "lt", "value" => 4}     # sequence < 4
    ],
    "on_fail"    => "continue"            # see below
  },
  "index"  => 1
}
```

**Condition format** — each entry has a `"key"`, a `"value"`, and an optional
`"op"` (defaults to `eq`). Supported ops:
`eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`, `empty`, `in`.

**`on_fail` behaviour:**

- `"halt"` *(default)* — if any condition fails, the step returns an error and
  the path stops (`condition_failed:<keys>`). Good for "stop unless valid".
- `"continue"` — always succeeds, returning `%{passed: false, failed_conditions: [...]}`,
  so a downstream **edge condition** can branch on `passed`.

**Output:** `%{passed: boolean, input: <original map>, failed_conditions: [...]}`.

> **Two kinds of "condition" — don't confuse them:**
> - **Condition *node*** (this section) — an action that *computes* `passed`.
> - **Edge condition** (§6) — a guard *on an edge* that decides whether to take
>   the path. They're often used together: a Condition node sets `passed`, and
>   edges branch with `%{"field" => "passed", "op" => "eq", "value" => true/false}`.

---

## 5. Steps

"Step" is the runtime view of a node: the engine writes a **step result row**
(`running` → `completed`/`failed`/`waiting`/`skipped`) around every node it
runs. Most steps are ordinary actions. A couple are **infrastructure steps**
worth knowing:

### Human-in-the-loop (approval gate)

`Zaq.Engine.Workflows.Steps.HumanInTheLoop` suspends the run until a person (or
agent) approves:

```elixir
%{
  "name"   => "review_email",
  "type"   => "action",
  "module" => "Zaq.Engine.Workflows.Steps.HumanInTheLoop",
  "params" => %{"message" => "Review and approve the drafted email before sending."}
}
```

When reached, the run transitions to **`waiting`**. Approval/rejection arrives
as an engine event:

```elixir
Zaq.Event.new(
  %{action: "run.approve", run_id: run_id, person_id: pid, decision: %{}},
  :engine, name: :workflow
)
```

On approval, downstream steps receive
`%{approved: true, decision: %{...}, approved_by: "..."}` as their input — so an
edge can gate the next step on `%{"field" => "approved", "op" => "eq", "value" => true}`.

### Other infrastructure steps

`EdgeStep` (evaluates edge guards), `MapCollect` (gathers `map` fan-out
results), `Run`, `Node` — these are wired automatically by the DAG builder; you
don't author them directly.

---

## 6. Edges

An edge connects two nodes and optionally controls **whether** the path is taken
and **what data** flows across it:

```elixir
%{
  from: "ensure_person",
  to:   "build_history",
  condition: %{"field" => "person", "op" => "not_empty"},   # only if person was found
  mapping:   %{"person_id" => "ensure_person.person.id"}    # feed person.id → next step's person_id
}
```

### Edge condition (the guard)

`condition` is a single check (not a list) with `"field"`, `"op"`, and usually
`"value"`. The `field` is read from the source step's output. Operators:

| Op          | Meaning                              |
|-------------|--------------------------------------|
| `eq`        | equal                                |
| `neq`       | not equal                            |
| `gt`/`lt`   | greater / less than                  |
| `gte`/`lte` | greater-or-equal / less-or-equal     |
| `not_empty` | truthy and non-blank                 |
| `empty`     | `nil`, `""`, `[]`, or `%{}`          |
| `in`        | membership (`value` must be a list)  |

If the condition is **false**, that path isn't followed (the downstream step is
skipped). Omit `condition` to always follow the edge.

### Edge mapping (the data)

`mapping` is `%{ "<downstream input key>" => "<source path>" }`. The source path
is either a field on the immediate upstream output (`"rows"`) or a **dotted
path** into a named step's output (`"ensure_person.person.id"`). The resolved
value is delivered to the next step under the target key.

```elixir
# take the upstream's `rows` and hand it to the next step as `items`
mapping: %{"items" => "rows"}

# pull a nested value from a specific earlier step
mapping: %{"person" => "ensure_person.person", "value" => "increment_email_state.value"}
```

### Branching pattern (Condition node + two edges)

```elixir
nodes: [
  %{"name" => "check", "type" => "action",
    "module" => "Zaq.Agent.Tools.Workflow.Condition",
    "params" => %{"input" => "{{row}}", "on_fail" => "continue",
                  "conditions" => [%{"key" => "active", "value" => true}]}},
  %{"name" => "do_active",   "type" => "action", "module" => "...", "params" => %{}},
  %{"name" => "do_inactive", "type" => "action", "module" => "...", "params" => %{}}
],
edges: [
  %{from: "check", to: "do_active",   condition: %{"field" => "passed", "op" => "eq", "value" => true}},
  %{from: "check", to: "do_inactive", condition: %{"field" => "passed", "op" => "eq", "value" => false}}
]
```

---

## 7. End-to-end example

A small, linear "draft → approve → send" workflow that ties Actions, a Step, and
Edges together:

```elixir
%{
  name: "Outreach with approval",
  status: "active",
  nodes: [
    %{
      "name" => "draft",
      "type" => "action",
      "module" => "Zaq.Agent.Tools.Workflow.RunAgent",
      "params" => %{
        "agent_id" => 42,
        "input" => "Draft an outreach email for {{name}} at {{company}}."
      },
      "index" => 0
    },
    %{
      "name" => "review",
      "type" => "action",
      "module" => "Zaq.Engine.Workflows.Steps.HumanInTheLoop",
      "params" => %{"message" => "Approve the draft before it is sent."},
      "index" => 1
    },
    %{
      "name" => "send",
      "type" => "action",
      "module" => "Zaq.Agent.Tools.People.NotifyPerson",
      "params" => %{"subject" => "Hello from ZAQ"},
      "index" => 2
    }
  ],
  edges: [
    # only review if the agent actually produced a draft
    %{from: "draft", to: "review",
      condition: %{"field" => "output", "op" => "not_empty"}},

    # only send once approved; hand the draft text to the sender as `message`
    %{from: "review", to: "send",
      condition: %{"field" => "approved", "op" => "eq", "value" => true},
      mapping:   %{"message" => "draft.output"}}
  ]
}
```

What happens at run time:

1. **`draft`** runs the agent; output is `%{output: "Hi …"}`.
2. The edge to **`review`** is followed only if `output` is non-empty.
3. **`review`** suspends the run (`waiting`) until someone approves.
4. On approval, the edge to **`send`** fires (because `approved == true`) and
   maps the drafted text into `send`'s `message` input.

---

## 8. Real, working references

The repository ships full example workflows — read these next:

- `lib/zaq/engine/workflows/example/send_leads_email.ex` — linear DAG with an
  agent draft, a human approval gate, increment + concat, and a sheet write.
- `lib/zaq/engine/workflows/example/identify_leads_from_google_sheet.ex` — a
  `map` fan-out with Condition steps and a `DispatchEvent` that triggers the
  workflow above.
- `lib/zaq/engine/workflows/dag_builder.ex` — the authoritative description of
  the `nodes`/`edges` format (including `map`/`batch` nodes).

To scaffold a new workflow module from a plain-English description, use the
`/create-workflow` skill, which maps each described step to a real action (or
flags missing tools).
