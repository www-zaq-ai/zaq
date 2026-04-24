# Execution Plan: Per-Person Agent Server Spawning

**Date:** 2026-04-24
**Author:** Claude
**Status:** `active`
**Related debt:** —
**PR(s):** —

---

## Goal

Unify the routing and agent-spawning logic so every incoming message — whether it flows through `Pipeline` or `Executor` — goes through the same lifecycle:

1. Identity is resolved **once** before the route decision.
2. A **per-person Jido server** is guaranteed to exist before any LLM call — spawned lazily on the first message, reused on every subsequent one, regardless of which channel the person writes from.
3. The pipeline's answering step uses that per-person server, giving it the same history management and BO-status-wiring behaviour as the executor path.
4. A kill function (`stop_server/1` extension) exists to terminate any per-person server on demand — this is the eviction mechanism; a follow-up issue will define when to call it.

**Expected children in `AgentServerSupervisor`** for N people and M configured agents: `N × (M + 1)`. Example: 3 people, 2 agents → **9 children** (3 answering + 6 executor). No singleton.

Done looks like: `Api.handle_event` resolves the person, derives a scope key, ensures the right server is in the supervision tree (spawning if absent), then hands control to `Pipeline` or `Executor` with the server ref in opts. Both paths behave consistently.

---

## Context

Files reviewed:

- [x] `lib/zaq/agent/api.ex` — routing entry point; currently splits on `selected_agent_id`
- [x] `lib/zaq/agent/pipeline.ex` — runs `IdentityPlug` inside `pre_do_run`; calls `Answering.ask` with the singleton server
- [x] `lib/zaq/agent/executor.ex` — calls `ServerManager.ensure_server(configured_agent)` using a shared per-agent-type server
- [x] `lib/zaq/agent/server_manager.ex` — manages Jido servers; has singleton `answering_singleton`; pre-starts all configured agents at init; has `ensure_server/1` for `ConfiguredAgent`
- [x] `lib/zaq/agent/answering.ex` — calls `ServerManager.answering_server()` (singleton) unconditionally
- [x] `lib/zaq/agent/factory.ex` — builds model specs and runtime configs
- [x] `lib/zaq/people/identity_plug.ex` — resolves `person_id` from channel author
- [x] `lib/zaq/engine/messages/incoming.ex` — `%Incoming{}` struct (no `conversation_id` field)
- [x] `lib/zaq_web/live/bo/communication/chat_live.ex` — BO chat; sets `provider: :web`, `channel_id: "bo"`, passes `session_id` in `metadata`

Key observations:

- `IdentityPlug` lives inside `Pipeline.pre_do_run` → runs only on the pipeline path, not the executor path.
- `IdentityPlug` resolves `person_id` from the channel author. The same person messaging via Mattermost or email gets the same `person_id` — cross-channel identity is handled by `People`.
- Executor uses a shared server per `ConfiguredAgent` ID (no user isolation).
- `Answering.ask` always uses `ServerManager.answering_server()` — global singleton being removed.
- `ServerManager.init` pre-starts the singleton and all active configured agents — both removed in this plan.
- For BO users, `person_id` is `nil` by policy. Per-session scope comes from `metadata.session_id`.

---

## Approach

### Identity resolution moves to `Api`

`Pipeline.pre_do_run` currently holds the `IdentityPlug` call. Moving it to `Api.handle_event` (before the route branch) means person resolution runs exactly once, is available for deriving the server scope, and a future migration to the Executor is easy (just cut-and-paste with the comment in place).

### Cross-channel identity: one person = one server

`person_id` is already cross-channel — the same person messaging from Mattermost, email, or Slack resolves to the same `person_id` via `IdentityPlug` + `People`. The server scope key is `person_id`, so a single Jido server accumulates history regardless of which channel the next message arrives on.

### Scope key for server IDs

| Condition | Scope key |
|---|---|
| `person_id` is not nil | `person_id` (integer → string) |
| `person_id` is nil AND BO channel | `metadata.session_id` |

BO channel = `incoming.provider == :web` OR `incoming.channel_id == "bo"`.

### Server IDs

| Path | Server ID |
|---|---|
| Pipeline (answering) | `"answering_#{scope}"` |
| Executor (selected agent) | `"configured_agent_#{agent_id}:#{scope}"` |

### Singleton removed entirely

`answering_singleton`, `start_answering_server/0`, and `answering_server/0` are all deleted from `ServerManager`. `Answering.ask` requires a `:server` opt — no fallback. `Api` always provides it.

### `init/1` becomes a no-op

Remove the `start_answering_server()` call and the `Agent.list_active_agents()` + `Enum.reduce` pre-spawning block. `init/1` returns `{:ok, %{}}`. All servers are spawned lazily per-message.

### Lazy spawning per-message

`ensure_answering_server/1` and `ensure_server_by_id/2` use the existing `safe_whereis` pattern: if a pid exists → return `{:ok, server_ref}` immediately; if not → start under `@dynamic_supervisor`. On every subsequent message the check short-circuits.

### Kill function

`stop_server/1` is extended with a new clause that accepts a raw binary server_id (e.g. `"answering_abc123"`), bypassing the `parse_int_id` + `agent_server_id` path and calling the already-private `stop_server_if_running/1` directly. No new public function — reuses existing private helper.

### `ServerManager` net change to public API

```
+ ensure_answering_server(server_id)    :: {:ok, GenServer.server()} | {:error, term()}
+ ensure_server_by_id(agent, server_id) :: {:ok, GenServer.server()} | {:error, term()}
+ last_active(server_id)                :: DateTime.t() | nil
~ stop_server/1 — new clause for raw string server_id, clears last_active
- answering_server/0 — deleted
```

### State shape

```elixir
%{
  fingerprints: %{integer() => String.t()},   # configured agent id => fingerprint
  last_active:  %{String.t() => DateTime.t()} # server_id => last message timestamp
}
```

`last_active` is stamped by every `ensure_answering_server` and `ensure_server_by_id` call — once per inbound message. The eviction follow-up issue reads it via `last_active/1`.

### Answering requires `:server` opt

`Answering.ask` accepts `:server` and uses it unconditionally. If absent, it raises — the caller (`Api` via `Pipeline`) is always responsible for providing the per-person server.

### Pipeline cleanup

Remove `identity_plug.call` from `Pipeline.pre_do_run` (`incoming.person_id` is now set before `Pipeline.run` is called). `pre_do_run` keeps only the typing event dispatch. `do_answering` threads `:server` from opts into `Answering.ask`.

---

## Steps

### RED Phase — write all failing tests first

- [ ] **Step 1 — `ServerManager` tests**
  - `test ensure_answering_server/1 starts server with given id and adds it to supervision tree`
  - `test ensure_answering_server/1 is idempotent — second call reuses existing server, no new process`
  - `test ensure_answering_server/1 same scope across two calls returns same server ref`
  - `test ensure_answering_server/1 returns error when supervisor not available`
  - `test stop_server/1 with raw server_id string terminates the server process`
  - `test stop_server/1 with raw server_id string is a no-op when server does not exist`
  - `test init/1 starts no servers — supervision tree is empty after start`
  - `test ensure_answering_server/1 stamps last_active timestamp on first call`
  - `test ensure_answering_server/1 updates last_active timestamp on repeated calls`
  - `test ensure_server_by_id/2 stamps last_active timestamp on each call`
  - `test last_active/1 returns nil for unknown server_id`
  - `test last_active/1 returns DateTime after ensure call`
  - `test stop_server/1 with raw server_id clears last_active entry`

- [ ] **Step 2 — `Api` tests (identity resolution + server spawning)**
  - `test identity resolution runs before route decision`
  - `test pipeline path: spawns answering server with answering_{person_id} scope`
  - `test pipeline path: nil person_id + BO provider uses metadata.session_id as scope`
  - `test executor path: spawns server with configured_agent_{id}:{person_id} scope`
  - `test executor path: nil person_id + BO provider uses metadata.session_id as scope`
  - `test server ref is passed through pipeline_opts to Pipeline.run`
  - `test server ref is passed through opts to Executor.run`
  - `test same person messaging twice reuses same server (no duplicate spawn)`

- [ ] **Step 3 — `Pipeline` tests (identity plug removed; server taken from opts)**
  - `test pre_do_run does not call identity_plug`
  - `test do_answering passes :server from opts to Answering.ask`
  - `test run/2 does not overwrite person_id already set on incoming`

- [ ] **Step 4 — `Answering` tests (`:server` opt required)**
  - `test ask/2 uses :server opt when provided`
  - `test ask/2 raises when :server opt is absent`

- [ ] **Step 5 — `Executor` tests (per-scope server)**
  - `test run/2 with :server_id opt uses scoped configured_agent_{id}:{scope} id`
  - `test run/2 without :server_id opt falls back to configured_agent_{id}`

---

### GREEN Phase — implementation to make tests pass

- [ ] **Step 6 — `ServerManager`: remove singleton; restructure state; simplify `init/1`**

  Delete `start_answering_server/0`, `answering_server/0`, and the `@answering_server_id` module attribute.

  **Restructure state shape.** The current flat map `%{integer_agent_id => fingerprint}` cannot hold per-server timestamps without collisions. Replace it with:

  ```elixir
  # %{
  #   fingerprints: %{integer() => String.t()},  # configured agent id => fingerprint
  #   last_active:  %{String.t() => DateTime.t()} # server_id => last message timestamp
  # }
  ```

  Update every `Map.get(state, int_id)` and `Map.put(state, int_id, fp)` in `do_ensure_server`, `handle_call({:stop_server, ...})`, and `handle_call({:ensure_server, ...})` to use `state.fingerprints` / `put_in(state, [:fingerprints, int_id], fp)`.

  `init/1` becomes:

  ```elixir
  def init(_opts), do: {:ok, %{fingerprints: %{}, last_active: %{}}}
  ```

- [ ] **Step 7 — `ServerManager`: add `ensure_answering_server/1`**

  Dispatches `{:ensure_answering_server, server_id}`. Handler: calls `safe_whereis(server_id)` — pid found or not, **always** stamps `last_active` then returns the ref:

  ```elixir
  state = put_in(state, [:last_active, server_id], DateTime.utc_now())
  ```

  If no pid: start `Jido.AgentServer` under `@dynamic_supervisor` with `agent: Factory`, `id: server_id`, `initial_state: %{model: Factory.build_model_spec()}`. Return `{:ok, server_ref(server_id)}`.

- [ ] **Step 8 — `ServerManager`: add `ensure_server_by_id/2`**

  Same logic as `do_ensure_server/2` but uses the caller-supplied `server_id` instead of `Agent.agent_server_id(configured_agent.id)`. Also stamps `last_active` on every call (existing server or new).

- [ ] **Step 8b — `ServerManager`: add `last_active/1`**

  ```elixir
  @spec last_active(String.t()) :: DateTime.t() | nil
  def last_active(server_id), do: GenServer.call(__MODULE__, {:last_active, server_id})
  ```

  Handler: `Map.get(state.last_active, server_id)`. Gives the eviction issue a clean read path.

- [ ] **Step 9 — `ServerManager`: extend `stop_server/1` for raw string ids; clear `last_active`**

  ```elixir
  def stop_server(server_id) when is_binary(server_id) do
    GenServer.call(__MODULE__, {:stop_server_by_raw_id, server_id})
  end
  ```

  Handler: calls `stop_server_if_running(server_id)`, removes `server_id` from `state.last_active`, returns `:ok`.

- [ ] **Step 10 — `Api`: move identity resolution; derive scope; spawn servers**

  ```elixir
  # TODO: move identity resolution to Executor once executor owns the full lifecycle
  incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)
  scope = derive_scope(incoming)
  ```

  Pipeline path: `ServerManager.ensure_answering_server("answering_#{scope}")` → add `server: server_ref` to `pipeline_opts`.

  Executor path: pass `server_id: "configured_agent_#{selected_id}:#{scope}"` in executor opts.

  Add private helpers `derive_scope/1` and `bo_channel?/1`.

- [ ] **Step 11 — `Pipeline`: remove identity plug; thread `:server` to answering**

  Remove `identity_plug_mod(opts).call(incoming, opts)` from `pre_do_run`. Remove the now-unused `identity_plug_mod/1` private accessor.

  In `do_answering`, add `server: Keyword.fetch!(opts, :server)` to `answer_opts`.

- [ ] **Step 12 — `Answering`: require `:server` opt**

  ```elixir
  server = Keyword.fetch!(opts, :server)
  ```

  Remove the `ServerManager` alias and all `answering_server()` calls from this module.

- [ ] **Step 13 — `Executor`: accept `:server_id` opt; use scoped server**

  When `server_id` opt is present, call `server_manager_module.ensure_server_by_id(configured_agent, server_id)` instead of `server_manager_module.ensure_server(configured_agent)`.

- [ ] **Step 14 — `mix precommit` passes; review coverage**

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Scope = `person_id` regardless of channel | `IdentityPlug` already unifies cross-channel identity. Same `person_id` from Mattermost or email → same server → shared history. | 2026-04-24 |
| Remove singleton `answering_singleton` entirely | Every message now provides a per-person server. A shared singleton has no role. Keeping it would mean two server starts per call with no benefit. | 2026-04-24 |
| `init/1` becomes `{:ok, %{}}` — no pre-spawning | Per-person server IDs are unknown at boot. Eager pre-spawning of any server is wrong in the new model. Lazy `ensure_*` on first message handles "not yet started" and "already running" via `safe_whereis`. | 2026-04-24 |
| `:server` opt is required in `Answering.ask`, not optional | `Api` always provides it. An absent `:server` is a caller bug, not a case to silently fall back on — fail fast with `Keyword.fetch!`. | 2026-04-24 |
| `stop_server/1` extended instead of new `stop_answering_server/1` | Reuses the existing public function and private `stop_server_if_running` helper. No new API surface. | 2026-04-24 |
| Use `metadata.session_id` as BO scope when `person_id` is nil | `current_conversation_id` is `nil` when `run_pipeline_async` fires — set only after response returns. `session_id` is generated at `mount`, stable for the full BO session, and present on every `Incoming.metadata`. | 2026-04-24 |
| Stamp `last_active` on every `ensure_*` call | `ensure_*` is called once per inbound message from `Api`. It is the single choke-point where all per-person server activity passes through — the right place to update the timestamp without instrumenting Jido internals. | 2026-04-24 |
| `last_active/1` is a read-only query for the eviction follow-up | The eviction logic belongs in a separate issue. This plan only provides the data it needs. | 2026-04-24 |
| State restructured to `%{fingerprints, last_active}` | The flat `%{integer => fingerprint}` map cannot hold string-keyed timestamps alongside integer-keyed fingerprints cleanly. Explicit sub-maps make each concern legible and prevent key collisions. | 2026-04-24 |
| Kill function is eviction mechanism, not tech debt | A follow-up issue will define when to call `stop_server` (idle timeout, conversation end, etc.). The function itself is in scope here. | 2026-04-24 |
| Comment "TODO: move to executor" in `Api` | The issue explicitly asks for this to signal future migration direction. | 2026-04-24 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| ~~Confirm `metadata.session_id` as BO scope~~ | ~~Jad~~ | resolved — `current_conversation_id` unavailable at dispatch time; `session_id` is the only stable per-session key on `Incoming` |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing (`mix test`)
- [ ] `mix precommit` passes
- [ ] `answering_singleton`, `answering_server/0`, and `start_answering_server/0` deleted from `ServerManager`
- [ ] `ServerManager.init` starts no servers — supervision tree is empty at boot
- [ ] `ServerManager` state is `%{fingerprints: %{}, last_active: %{}}` shape
- [ ] Every `ensure_answering_server` and `ensure_server_by_id` call stamps `last_active`
- [ ] `last_active/1` returns `DateTime.t()` after a message is processed, `nil` before
- [ ] `Answering.ask` uses `Keyword.fetch!(:server)` — no fallback
- [ ] Plan moved to `docs/exec-plans/completed/`
