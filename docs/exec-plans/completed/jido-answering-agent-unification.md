# Exec Plan: Unify Answering Agent Through Executor

**Branch:** `fix/jido-agents`
**Status:** Completed (2026-04-24)

---

## Context

`Answering` currently owns all the execution logic: Jido server management, logprobs analysis, result normalization. The goal is to make `Executor` the single execution boundary for **all** agent calls, and reduce `Answering` to a thin hardcoded module (tools list, no-answer signals) — the same role a DB-configured agent plays, but without the DB.

---

## Architecture

### Current flows

```
No agent selected:
Api → ensure_answering_server("answering_#{scope}")
    → pipeline_module.run(incoming, server: server_ref)
        → [retrieval, context, system_prompt]
        → Answering.ask(system_prompt, opts)   ← owns server lifecycle, logprobs, normalize
            → Jido server

Agent selected:
Api → executor_module.run(incoming, agent_id: id, scope: scope)
    → [ensure server, ask_with_config, await]
    → Outgoing
```

### Target flows

```
No agent selected:
Api → pipeline_module.run(incoming, pipeline_opts)   ← no server_ref, scope passed as opt
    → [retrieval, context, system_prompt]
    → executor_module.run(incoming, agent_id: nil, scope: scope, system_prompt: system_prompt, ...)
        → Factory.answering_configured_agent()
        → ensure_server_by_id("answering:#{scope}")
        → ask_with_config / await
        → LogprobsAnalyzer   ← moved from Answering to Executor
        → normalize_result   ← moved from Answering to Executor
        → Outgoing

Agent selected:
Api → executor_module.run(incoming, agent_id: id, scope: scope)
    → [ensure server, ask_with_config, await]
    → LogprobsAnalyzer   ← now runs for ALL agents
    → normalize_result   ← now runs for ALL agents
    → Outgoing
```

**Api keeps 2 paths** — Pipeline for no-agent, Executor for agent-selected. Pipeline delegates to Executor for the answering step instead of calling `Answering.ask` directly.

**Side effect (intentional):** configured agents now also get logprobs analysis and confidence scoring, since that logic lives in Executor.

### Server ID format

`ensure_server_by_id` is used (not `ensure_server`) to preserve per-person scoping.
Format changes from `"answering_#{scope}"` → `"answering:#{scope}"` (colon, consistent with configured agent scoping pattern `"#{name}:#{scope}"`).
Runtime-only Jido registry key — no migration needed.

---

## Decision: Zaq.Agent.History

**Keep it.** Actively used by both Executor and Answering. Future role: reload history when a Jido agent restarts. Do not delete.

---

## What `Answering` becomes after this refactor

A thin module that defines:
- `@answering_tools` — the tools list passed to the Jido server
- `@no_answer_signals` — signal strings for confidence analysis (still referenced by `LogprobsAnalyzer`)
- No `ask/2`, no logprobs calls, no result normalization

---

## Red Phase — Write failing tests first

All tests must fail before any production code is touched.

### Step R1 — Factory: `answering_configured_agent/0`

**File:** `test/zaq/agent/factory_test.exs`

```elixir
describe "answering_configured_agent/0" do
  test "returns a ConfiguredAgent with name answering" do
    agent = Factory.answering_configured_agent()
    assert %ConfiguredAgent{} = agent
    assert agent.id == :answering
    assert agent.name == "answering"
  end
end
```

**Fails because:** `Factory.answering_configured_agent/0` does not exist.

---

### Step R2 — Executor: `derive_scope/1` is public

**File:** `test/zaq/agent/executor_test.exs`

```elixir
describe "derive_scope/1" do
  test "uses person_id when present" do
    assert Executor.derive_scope(%Incoming{person_id: 42}) == "42"
  end

  test "falls back to session_id when person_id is nil" do
    incoming = %Incoming{person_id: nil, metadata: %{session_id: "sess-abc"}}
    assert Executor.derive_scope(incoming) == "sess-abc"
  end

  test "returns 'anonymous' when both are absent" do
    assert Executor.derive_scope(%Incoming{person_id: nil, metadata: %{}}) == "anonymous"
  end
end
```

**Fails because:** `Executor.derive_scope/1` does not exist — it is private in `Api`.

---

### Step R3 — Executor: answering agent path (nil `agent_id`)

**File:** `test/zaq/agent/executor_test.exs`

```elixir
describe "run/2 — answering agent (no agent_id)" do
  defmodule StubFactoryAnswering do
    def answering_configured_agent,
      do: %ConfiguredAgent{id: :answering, name: "answering", strategy: "react"}

    def ask_with_config(server_id, _query, _agent), do: {:ok, make_ref()}
    def await(_ref, _opts), do: {:ok, %{answer_text: "hi", logprobs: nil}}
    def runtime_config(_agent), do: {:ok, %{system_prompt: ""}}
    def generation_opts, do: []
  end

  defmodule StubSMAnswering do
    def ensure_server_by_id(_agent, server_id) do
      send(self(), {:ensure_server_by_id, server_id})
      {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
    end
  end

  test "routes through answering configured agent, scoped per person" do
    incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 5}

    result = Executor.run(incoming,
      factory_module: StubFactoryAnswering,
      server_manager_module: StubSMAnswering,
      scope: "5"
    )

    assert %Outgoing{} = result
    assert_received {:ensure_server_by_id, "answering:5"}
  end
end
```

**Fails because:** `Executor.run/2` with no `agent_id` returns `{:error, :missing_agent_selection}`.

---

### Step R4 — Executor: logprobs and normalize_result run for all agents

**File:** `test/zaq/agent/executor_test.exs`

```elixir
test "records confidence signal from logprobs for configured agent" do
  # stub factory returns logprobs in answer
  # assert Executor produces a result with confidence attached
  # (exact assertion depends on how LogprobsAnalyzer attaches confidence)
end
```

**Fails because:** logprobs analysis currently only happens inside `Answering.ask/2`, not in `Executor`.

---

### Step R5 — Pipeline: answering step calls executor, not Answering.ask

**File:** `test/zaq/agent/pipeline_test.exs`

```elixir
test "delegates answering step to executor_module" do
  # stub executor records call
  # assert Answering.ask is NOT called
  # assert executor_module.run IS called with system_prompt opt
end
```

**Fails because:** `Pipeline.run` currently calls `Answering.ask/2` directly (via NodeRouter).

---

### Step R6 — ServerManager: `ensure_answering_server/1` is removed

**File:** `test/zaq/agent/server_manager_test.exs`

```elixir
test "ensure_answering_server/1 no longer exists" do
  refute function_exported?(ServerManager, :ensure_answering_server, 1)
end
```

**Fails because:** the function currently exists.

---

## Green Phase — Make tests pass in order

Run `mix precommit` after each step.

### Step G1 — `Factory.answering_configured_agent/0`

**File:** `lib/zaq/agent/factory.ex`

```elixir
@spec answering_configured_agent() :: ConfiguredAgent.t()
def answering_configured_agent do
  %ConfiguredAgent{
    id: :answering,
    name: "answering",
    strategy: "react",
    enabled_tool_keys: [],
    conversation_enabled: false,
    active: true,
    advanced_options: %{}
  }
end
```

LLM config (model, credential) is resolved at runtime via `generation_opts()` — no DB lookup needed.

**Passes:** R1.

---

### Step G2 — Move `derive_scope/1` from `Api` to `Executor` (public)

**File:** `lib/zaq/agent/executor.ex`

Add public clauses (copy from Api's private `derive_scope/1`).

**File:** `lib/zaq/agent/api.ex`

Remove `defp derive_scope/1`. Replace call site with `Executor.derive_scope(incoming)`.

**Passes:** R2.

---

### Step G3 — `Executor.run/2`: handle nil `agent_id` → answering path

**File:** `lib/zaq/agent/executor.ex`

Update `load_selected_agent` to return the hardcoded answering agent when `agent_id` is nil:

```elixir
defp load_selected_agent(opts, agent_module, factory_module) do
  case Keyword.get(opts, :agent_id) do
    nil -> {:ok, factory_module.answering_configured_agent()}
    agent_id -> agent_module.get_configured_agent(agent_id)
  end
end
```

`ensure_agent_server` already routes through `ensure_server_by_id` when `scope` is present, producing `"answering:#{scope}"`. No changes needed there.

**Passes:** R3.

---

### Step G4 — Move logprobs analysis and `normalize_result` from `Answering` to `Executor`

**File:** `lib/zaq/agent/executor.ex`

Move `LogprobsAnalyzer` call and `normalize_result` into the `Executor` result-handling path so all agents benefit.

**File:** `lib/zaq/agent/answering.ex`

Remove `ask/2`, logprobs calls, and `normalize_result`. Keep:
- `@answering_tools`
- `@no_answer_signals` (still read by `LogprobsAnalyzer`)

**Passes:** R4.

---

### Step G5 — `Pipeline.run`: replace `Answering.ask` call with `executor_module.run`

**File:** `lib/zaq/agent/pipeline.ex`

Replace the `node_router.call(:agent, answering_mod, :ask, ask_args)` step with a call to `executor_module.run(incoming, agent_id: nil, scope: scope, system_prompt: system_prompt, ...)`.

Remove the `server:` opt from the pipeline opts — the server is now managed entirely inside Executor.

Also add the inline comment on the `identity_plug_mod` call in `Api` (without a TODO tag):

```elixir
# identity resolution — moving to Executor in a follow-up refactor
incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)
```

**Passes:** R5.

---

### Step G6 — Remove `ensure_answering_server` from `ServerManager`

**File:** `lib/zaq/agent/server_manager.ex`

Delete:
- `ensure_answering_server/1` public spec + function
- `handle_call({:ensure_answering_server, ...}, ...)` clause
- Any helpers used only by that path

**Passes:** R6.

---

## Validation

```bash
mix test test/zaq/agent/factory_test.exs
mix test test/zaq/agent/executor_test.exs
mix test test/zaq/agent/pipeline_test.exs
mix test test/zaq/agent/api_test.exs
mix test test/zaq/agent/server_manager_test.exs
mix precommit
```

---

## File Map

| File | Change |
|---|---|
| `lib/zaq/agent/factory.ex` | Add `answering_configured_agent/0` |
| `lib/zaq/agent/executor.ex` | Public `derive_scope/1`; nil `agent_id` → answering path; absorb logprobs + normalize_result |
| `lib/zaq/agent/answering.ex` | Strip to thin module: tools + no_answer_signals only |
| `lib/zaq/agent/api.ex` | Remove `derive_scope/1`; add inline comment on identity_plug_mod; keep 2 paths |
| `lib/zaq/agent/pipeline.ex` | Replace `Answering.ask` call with `executor_module.run`; remove `server:` opt |
| `lib/zaq/agent/server_manager.ex` | Remove `ensure_answering_server/1` and its `handle_call` clause |
| `test/zaq/agent/factory_test.exs` | New: `answering_configured_agent/0` tests |
| `test/zaq/agent/executor_test.exs` | New: `derive_scope/1`; answering path; logprobs for all agents |
| `test/zaq/agent/pipeline_test.exs` | New: executor called for answering step |
| `test/zaq/agent/api_test.exs` | Existing tests stay valid — Api shape unchanged |
| `test/zaq/agent/server_manager_test.exs` | New: `ensure_answering_server/1` does not exist |

---

## Out of Scope

- Deleting `Zaq.Agent.History` — keep (used for history restoration on agent restart).
- Moving `identity_plug_mod` to Executor — noted with inline comment, deferred to follow-up.
