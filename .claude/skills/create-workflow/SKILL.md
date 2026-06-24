---
name: create-workflow
description: Turn a plain-text description of a business workflow into a ZAQ workflow use-case module (a `Zaq.Engine.Workflows.UseCases.*` module that builds a DAG of nodes + edges). Every step is mapped to a real tool from `lib/zaq/agent/tools` (resolved through `Zaq.Agent.Tools.Registry`) or a workflow Step like `HumanInTheLoop`. When a described step has no matching tool, the generated module gets a `missing_tools/0` function describing the tools that must be built first. Use when the user pastes/says a workflow they want as code.
trigger: when the user types /create-workflow or asks to turn a described workflow into a workflow module
---

# Create Workflow Skill

You convert a **plain-language workflow description** into a ZAQ workflow use-case
module shaped exactly like
`lib/zaq/engine/workflows/example/send_leads_email.ex`.

**Announce at start:** "Using /create-workflow — building the tool catalog, then mapping your steps."

The hard rule: **every node's `module` must be a tool that actually exists.**
Steps come from `lib/zaq/agent/tools` (via the registry) or from
`lib/zaq/engine/workflows/steps/`. If a step the user describes has no real tool,
you do **not** invent a module path — you record it in `missing_tools/0` instead.

---

## File write restrictions

You may ONLY create/write the generated workflow module under:

| Allowed path | Rule |
|---|---|
| `lib/zaq/engine/workflows/example/` | New `Zaq.Engine.Workflows.UseCases.*` use-case modules. One file per workflow. |

Do **not** edit the registry, tool modules, the engine, or anything else. If the
workflow needs a new tool, that is what `missing_tools/0` is for — describe it,
don't build it here.

---

## Step 1 — Build the live tool catalog (never hardcode it)

Tool lists drift. Always rebuild the catalog from source at run time. Use one
sandboxed command (per the context-mode rules) and print a compact catalog:

1. Read the registry to get the canonical `{key, label, description, module}`
   list: `lib/zaq/agent/tools/registry.ex` (the `@tools` list).
2. For each tool module under `lib/zaq/agent/tools/**`, extract its
   `use Zaq.Engine.Workflows.Action` (or `use Jido.Action`) declaration —
   specifically `name:`, `description:`, the `schema:` (input params), and
   `output_schema:` (fields downstream nodes can map from).
3. Also include the workflow Steps in `lib/zaq/engine/workflows/steps/` that are
   usable as nodes — notably `Zaq.Engine.Workflows.Steps.HumanInTheLoop`
   (human-in-the-loop approval; produces `approved`).

Suggested gather (run in sandbox, print only the summary):

```shell
sed -n '1,400p' lib/zaq/agent/tools/registry.ex
grep -Rn "use Zaq.Engine.Workflows.Action\|use Jido.Action\|name:\|schema:\|output_schema:\|type:\|required:\|doc:" lib/zaq/agent/tools
ls lib/zaq/engine/workflows/steps
```

Produce an in-memory catalog where each entry is:

```
module (e.g. Zaq.Agent.Tools.People.NotifyPerson)
key    (e.g. accounts.fetch_history — only if registry-listed)
purpose (one line)
inputs  (param -> {type, required?})    ← from schema:
outputs (field -> type)                 ← from output_schema:
```

Only modules present in `@tools` are agent-usable, BUT the example workflow also
uses workflow-contract modules directly by module string (e.g.
`Zaq.Agent.Tools.Workflow.RunAgent`, `Zaq.Agent.Tools.Workflow.Increment`,
`Zaq.Engine.Workflows.Steps.HumanInTheLoop`). Treat any module that `use`s
`Zaq.Engine.Workflows.Action` (or is a Step) as a valid node module.

---

## Step 2 — Read the template

Read `lib/zaq/engine/workflows/example/send_leads_email.ex` and treat it as the
canonical shape. Mirror its structure exactly:

- `defmodule Zaq.Engine.Workflows.UseCases.<Name> do`
- Module-attribute aliases for each node module (`@xxx_module "Zaq.Agent.Tools..."`).
- `create(opts \\ [])` — wraps `build/1` in a `Zaq.Repo.transaction`, calls
  `Workflows.create_workflow/1`, then `create_trigger/1` +
  `assign_workflow_to_trigger/2`. Pick the trigger style from the description:
  - event-driven → `Workflows.create_trigger(%{event_name: "..."})`
  - scheduled → `create_trigger(%{event_name: "...", trigger_type: "cron", cron_schedule: "0 9 * * *"})`
    (see `identify_leads_from_google_sheet.ex` for the cron form)
- `build(opts \\ [])` — returns the `%{name:, status: "active", nodes: [...], edges: [...]}` map.
- Each node: `%{name:, type: "action", module: @x_module, params: %{...}, index: n}`.
  Use `type: "map"` for per-item fan-out (see `identify_leads_from_google_sheet.ex`).
- Each edge: `%{from:, to:, condition: %{"field" =>, "op" =>, "value" =>}, mapping: %{"target_param" => "source_node.output.path"}}`.
  `condition` and `mapping` are both optional per edge.

---

## Step 3 — Parse the description into ordered steps

Break the user's text into discrete steps in execution order. For each step
capture: the action verb, the subject/object, any literal config (sheet id,
subject line, cron, event name), and what data it needs from earlier steps.

If the description is ambiguous about trigger type, target IDs, or ordering, ask
**one** concise batched clarifying question via AskUserQuestion before generating.
Otherwise proceed with sensible defaults exposed as `opts` (like the template's
`:sheet_id`, `:provider`, `:agent_name`).

---

## Step 4 — Map each step to a tool

For each parsed step, find the best-matching catalog entry by purpose + inputs.

- **Match found** → add a node using that module; fill `params` from the step's
  literals; wire an edge from the previous node, mapping the new node's required
  inputs to upstream `output_schema` fields (`"param" => "prev_node.field"`).
- **Human approval / review step** → use
  `Zaq.Engine.Workflows.Steps.HumanInTheLoop`; downstream edge condition is
  `%{"field" => "approved", "op" => "eq", "value" => true}`.
- **"draft/generate with AI" step** → use `Zaq.Agent.Tools.Workflow.RunAgent`
  with `params: %{"agent_name" => ..., "input" => "...{{template}}..."}`; its body
  is returned as `output`.
- **No reasonable match** → do NOT invent a module. Record it as a missing tool
  (Step 5) and insert a placeholder node only if structurally needed; otherwise
  leave the gap and let `missing_tools/0` document it.

Validate every `mapping` source against the upstream node's real `output_schema`
fields and every `param` against the node module's `schema`. Never map to a field
that doesn't exist.

---

## Step 5 — `missing_tools/0` for unmatched steps

If one or more steps had no matching tool, add this function to the generated
module and reference it in the `@moduledoc` ("⚠ Requires tools: see
`missing_tools/0`"). It returns structured suggestions so a developer can build
them and add them to the registry:

```elixir
@doc """
Tools this workflow needs that do not yet exist in `lib/zaq/agent/tools`.
Build each one as a `use Zaq.Engine.Workflows.Action` module, then (for agent
use) register it in `Zaq.Agent.Tools.Registry`. Until then this workflow cannot
run end-to-end.
"""
@spec missing_tools() :: [map()]
def missing_tools do
  [
    %{
      step: "<the step from the user's description>",
      suggested_module: "Zaq.Agent.Tools.<Domain>.<Name>",
      suggested_key: "<domain>.<snake_action>",
      purpose: "<one line>",
      suggested_schema: [
        # param: [type: :string, required: true, doc: "..."]
      ],
      suggested_output_schema: [
        # result: [type: :map, required: true, doc: "..."]
      ]
    }
  ]
end
```

When there are no missing tools, omit the function entirely.

---

## Step 6 — Write, format, validate

1. Write the module to `lib/zaq/engine/workflows/example/<snake_name>.ex` with a
   `@moduledoc` that documents the DAG (ASCII flow like the template), the trigger,
   the expected input shape, and a `## Usage` example.
2. Run `mix format` on the new file.
3. Run `mix compile` (or `mix q` if the user wants the full gate) and fix any
   compile errors in the generated file only.

---

## Step 7 — Report

Output a short summary:
- File path created.
- A table of steps → mapped module (or **MISSING**).
- If anything is missing: the list from `missing_tools/0` and the one-line next
  step ("build these tools, register them, then re-run /create-workflow").

Keep the final response under 500 words. The module is the artifact — don't paste
it inline; give the path plus the step→tool table.
