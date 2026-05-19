# How Jido/Runic Passes Events Between Workflow Steps

A precise, code-grounded trace of the event-passing mechanism. Steps **never call
each other** and there is **no shared accumulator** — communication happens
entirely through events folded into a shared graph.

File references are into `deps/runic/lib/workflow.ex` unless otherwise noted.

---

## 1. The graph model

A Runic workflow is a `Multigraph` whose **vertices are both structural nodes**
(Root, `ActionNode`, `Step`, `Join`) **and `%Fact{}` data vertices**. Edges are
labelled and fall into two classes:

- **Structural `:flow` edges** — built once at construction time
  (`DagBuilder` → `Workflow.add` / `Runic.Component.connect`). They encode
  "Step A feeds Step B". Immutable for the duration of a run.
- **Runtime edges** — drawn/relabelled during execution:
  - `:produced` — producing node → its result `%Fact{}`
  - `:runnable` / `:matchable` — a `%Fact{}` → a step that is now ready to
    consume it
  - consumed / `:ran` markers, `:upstream_failed`, `:joined`, etc.

"Is there work left?" is answered by `is_runnable?/1` (`:3314`):

```elixir
def is_runnable?(%__MODULE__{graph: graph}) do
  not Enum.empty?(Multigraph.edges(graph, by: [:runnable, :matchable]))
end
```

i.e. *does any `:runnable`/`:matchable` edge exist?*

---

## 2. The drive loop — `react_until_satisfied/3` (`:2884`)

1. Injects the seed fact at the **root** node via `invoke(root(), fact)`
   (`:2743-2748`).
2. Loops in `do_react_until_satisfied` (`:2914-2926`): while `is_runnable?`,
   call `react/1`.

`react/1` (`:2706`):

- `prepare_for_dispatch/1` → list of `%Runnable{}`
- `Invokable.execute(runnable.node, runnable)` for each, serially
  (`:2754-2767`)
- `Enum.reduce` folding each executed runnable back via `apply_runnable/2`

`prepare_for_dispatch/1` (`:3527`) iterates **every** `:runnable`/`:matchable`
edge `%Edge{v2: node, v1: fact}` and calls `Invokable.prepare(node, wrk, fact)`:

```elixir
Multigraph.edges(graph, by: [:runnable, :matchable])
|> Enum.reduce({workflow, []}, fn %Multigraph.Edge{v2: node, v1: fact}, {wrk, runnables} ->
  case Invokable.prepare(node, wrk, fact) do
    {:ok, runnable} -> {wrk, [runnable | runnables]}
    ...
```

**This is the entire input-binding contract:** a step receives its input fact as
the `v1` (Fact) endpoint of the runnable edge whose `v2` is that step.

---

## 3. How a step's output becomes the next step's input — `apply_runnable/2` (`:3568`)

`Invokable.execute/2` packages results as **events** inside the Runnable. For
`Jido.Runic.ActionNode`
(`deps/jido_runic/lib/jido/runic/action_node.ex:199-257`):

- `result_fact = Fact.new(value: result, ancestry: {node.hash, input.hash})`
- events: `%FactProduced{value: result, ancestry: …, producer_label: :produced}`
  and `%ActivationConsumed{fact_hash: input.hash, node_hash: node.hash}`
- `Runnable.complete(runnable, result_fact, events, hook_fns)`

`apply_runnable/2` then, in order:

1. **Fold core events** (`:3574`):
   - `apply_event(%FactProduced{})` (`:942`) — materializes the result
     `%Fact{}` as a graph vertex, draws `producer_node --:produced--> fact`.
   - `apply_event(%ActivationConsumed{})` (`:963`) — `mark_runnable_as_ran`:
     clears the `:runnable` edge that fed *this* step so it can't re-fire.
2. `apply_hook_fns` (`:3577`).
3. **`maybe_finalize_coordination`** (`:3681`) — if the node has a
   `Runic.Workflow.Coordinator` impl (fan-in `Join`), it checks whether *all*
   required parent facts have arrived and only then emits the combined
   downstream fact.
4. **`emit_downstream_activations`** (`:3651`) — the actual hand-off:

```elixir
defp default_emit_downstream(wf, %Runnable{result: result, node: node}) do
  next = next_steps(wf, node)               # structural :flow successors
  activation_events =
    Enum.map(next, fn step ->
      %RunnableActivated{
        fact_hash: result.hash,
        node_hash: step.hash,
        activation_kind: Private.connection_for_activatable(step)
      }
    end)
  wf = Enum.reduce(activation_events, wf, &apply_event(&2, &1))
  {wf, activation_events}
end
```

`apply_event(%RunnableActivated{})` (`:985`) draws
`result_fact --:runnable--> downstream_step`.

**Net effect:** after Step A completes, the graph holds a fresh `:runnable`
edge from **A's result fact** to every structurally-connected Step B. On the
next loop tick `is_runnable?` sees it, `prepare_for_dispatch` builds B's
Runnable with `input_fact = A's result fact`, and B executes. **That edge *is*
the message from A to B.**

---

## 4. Fan-in (a step with multiple parents)

`DagBuilder`'s `Runic.Component.connect/3` with a parent list builds a
`Runic.Workflow.Join`
(`deps/jido_runic/lib/jido/runic/action_node.ex:349-368`). The Join has a
`Coordinator` impl, so phase 3 (`maybe_finalize_coordination`) **withholds
downstream activation until every parent fact has been received**, then emits a
single combined fact. A 2-parent step runs **once**, not twice.

---

## 5. Failure / condition pruning

`apply_runnable` for `%Runnable{status: :failed}` (`:3621`) →
`handle_failed_runnable` (`:3689`) → `mark_runnable_as_ran` +
`skip_downstream_subgraph/2` (`:3709`): walks transitive `:flow` descendants and
relabels their pending `:runnable`/`:joined` edges to `:upstream_failed`, so the
drive loop terminates instead of deadlocking on a fact that will never be
produced.

This is exactly how ZAQ's `ConditionNotMet` raise (a failed runnable) prunes the
downstream branch of a workflow.

---

## 6. Per-step input/output detail (ZAQ specifics)

In `Jido.Runic.ActionNode.execute/2`
(`deps/jido_runic/lib/jido/runic/action_node.ex:201`):

```elixir
merged_params =
  Map.merge(node.params, to_params(fact.value), fn _k, _node_val, fact_val -> fact_val end)
```

- `node.params` = the static `"params"` from the step's JSONB node = **defaults**
- `fact.value` = the incoming fact = **the previous step's output map** (or the
  seed input for the first step)
- `to_params/1` (`:240`) wraps a non-map fact value as `%{input: value}`
- conflict resolver returns `fact_val` → **the upstream output overrides the
  static params** on key collisions

On success (`:205`):

```elixir
result_fact = Fact.new(value: result, ancestry: {node.hash, fact.hash})
```

The new fact's value is **exactly the action's returned map**. `ancestry` is
lineage metadata only — it carries **no data forward**.

> ⚠️ **Doc discrepancy:** `docs/services/workflows.md` → "Fact Flow" step 4
> claims *"Runic merges the result map into the running fact for downstream
> nodes."* This is **false**. There is **no accumulation** — step N+1 sees only
> step N's output map (overlaid on its own static params). If `fetch` returns
> `%{emails: […]}` and `classify` returns `%{label: "x"}`, a third step sees
> only `%{label: "x"}`; `emails` is gone. Each action must explicitly re-emit
> any field later steps need.

The seed fact is `source_event.assigns[:input]` (falling back to the full
`assigns`, then `%{}`) — `lib/zaq/engine/workflows/workflow_agent.ex:50-55`.

When a `run_id` is present, `DagBuilder` makes `node.action_mod` the
`ActionWrapper`, which strips `@wrapper_keys`, calls the real action, and
normalizes to `{:ok, result}` — so the wrapper is transparent to fact flow.
