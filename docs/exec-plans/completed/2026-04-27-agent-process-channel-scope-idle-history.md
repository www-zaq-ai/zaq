# Execution Plan: Agent Process Channel Scope, Idle TTL, and History Reload

**Date:** 2026-04-27
**Author:** Claude
**Status:** `completed`
**Related debt:** —
**PR(s):** —

---

## Goal

Three open items from the agent process issue on branch `feat/agent-process`:

1. **Per-channel scoping** — an agent server must be spawned per `(agent, person, channel)` triplet, not just per `(agent, person)`. A person talking to agent "Yo" via Mattermost gets `"Yo:mattermost-2"`, via email gets `"Yo:email-2"`. This prevents cross-channel history bleed.
2. **Per-agent idle TTL** — the existing 30-min default idle TTL must be configurable per agent in the BO admin UI. Each server is shut down after its own configured idle period.
3. **History reload on restart** — when a killed process is re-spawned, the last N messages for that `(person, channel)` pair are loaded from the DB and injected as `initial_state.history`, bounded by a configurable `memory_context_max_size` (default 5,000 tokens).

Done looks like: two new integer fields on `configured_agents`, channel dimension in all server IDs, idle timers resetting on each incoming message, and history hydrating new processes from DB.

---

## Context

Docs read:
- [x] `docs/services/agent.md` — agent pipeline, server lifecycle
- [x] `docs/architecture.md` — NodeRouter boundaries
- [x] `docs/conventions.md` — module ownership rules

Existing code reviewed:
- `lib/zaq/agent/executor.ex` — `derive_scope/1` (currently uses `person_id` only, no provider), `ensure_agent_server/3` (builds `"#{name}:#{scope}"` server ID)
- `lib/zaq/agent/server_manager.ex` — `ensure_server_by_id/2`, `spawn_agent_server/2`, `idle_ttl_ms/0` (only applied to raw-string path), no timer cancellation/reset
- `lib/zaq/agent/history.ex` — `build/1`, `entry_key/2` — history map format `%{"<ts>_1_user" => %{"body", "type"}}`
- `lib/zaq/agent/token_estimator.ex` — `estimate/1` — word × 1.3 heuristic
- `lib/zaq/agent/configured_agent.ex` — no `idle_time_seconds` or `memory_context_max_size` fields yet
- `lib/zaq/engine/conversations.ex` — `list_conversations/1` supports `person_id`, `channel_type` filters
- `lib/zaq/engine/conversations/message.ex` — `role`, `content`, `inserted_at` fields available for history rebuild
- `lib/zaq_web/live/bo/ai/agents_live.ex` — BO admin form for `ConfiguredAgent`

### Infrastructure Audit

- `derive_scope/1` already exists in `Executor` and is the single place for scope string derivation — extend it, do not create a parallel function.
- `ensure_server_by_id/2` in `ServerManager` is the correct spawn-or-reuse entry point for scoped configured agents — extend it, do not duplicate.
- `spawn_agent_server/2` is the private function that builds `initial_state` and calls `DynamicSupervisor.start_child` — history injection belongs here.
- `TokenEstimator.estimate/1` already exists for token counting — use it for the history truncation loop.
- `History.build/1` converts the history map to `ReqLLM.Message` structs — the DB load must produce the same map format so `History.build` works unchanged.
- No existing `HistoryLoader` module — a new `Zaq.Agent.HistoryLoader` module is required for DB→history-map conversion; this is a narrow, testable boundary.
- `idle_ttl_ms/0` is a private helper in `ServerManager` read from application env — keep it as the system default fallback; per-agent TTL is resolved from `configured_agent.idle_time_seconds` at call time.

---

## Approach

### Step 1 — Channel-aware scope

`Executor.derive_scope/1` currently returns `person_id` as a bare string. Extend it to prepend the normalized provider:

```
derive_scope(%Incoming{provider: :mattermost, person_id: 2}) → "mattermost-2"
derive_scope(%Incoming{provider: :web, metadata: %{session_id: "abc"}}) → "bo-abc"
```

The server ID construction in `ensure_agent_server/3` already does `"#{name}:#{scope}"`, so server IDs become `"Yo:mattermost-2"` and `"answering_mattermost-2"` automatically without touching that line.

`normalize_provider/1` is a private helper in `Executor` that converts the provider atom/string to a safe, lowercase, hyphen-free identifier (`:"email:imap"` → `"email_imap"`, `:web` → `"bo"`, atoms → `Atom.to_string/1`).

### Step 2 — New fields on ConfiguredAgent

Migration adds two nullable integer columns to `configured_agents`:
- `idle_time_seconds` — overrides system default; `nil` = use `Application.get_env(:zaq, :agent_server_idle_ttl_ms, 1_800_000) / 1000`
- `memory_context_max_size` — max tokens of history to inject on restart; `nil` = 5,000

`ConfiguredAgent` schema and changeset updated accordingly. Both fields exposed in `agents_live` form (number inputs with placeholder hints).

### Step 3 — Per-agent idle TTL with reset

`ServerManager` state gains a `timers` sub-map: `%{server_id => timer_ref}`.

On every `ensure_server_by_id` call (whether the server already exists or was just spawned):
1. Cancel any existing timer for that `server_id` via `Process.cancel_timer/1`.
2. Compute the TTL: `(configured_agent.idle_time_seconds || system_default_s) * 1_000`.
3. Schedule `Process.send_after(self(), {:expire_server, server_id}, ttl_ms)`.
4. Store the new ref in `state.timers`.

`handle_info({:expire_server, server_id}, state)` already calls `stop_server_if_running` — extend it to also delete the entry from `state.timers`.

`ensure_server_by_id/2` public signature gains `configured_agent` → TTL is read from it inside the GenServer handler. No other callers are affected since `ensure_server_by_id/2` already receives `ConfiguredAgent`.

### Step 4 — History injection on restart

`Zaq.Agent.HistoryLoader` — new module. Responsible for:
1. Querying the last messages for a `(person_id, channel_type)` pair (most recent first).
2. Accumulating messages until `TokenEstimator.estimate/1` sum would exceed `max_tokens`.
3. Reversing to chronological order.
4. Converting each `Message` struct into the `%{"body" => content, "type" => "bot"|"user"}` format used by `History.build/1`, keyed by `History.entry_key(inserted_at, role)`.

`spawn_agent_server/2` (private in `ServerManager`) currently takes `(configured_agent, server_id)`. It needs `person_id` and `channel_type` to load history. Extend `ensure_server_by_id` GenServer call message to carry `{:ensure_server_by_id, configured_agent, server_id, spawn_opts}` where `spawn_opts = %{person_id: ..., channel_type: ...}`. When `safe_whereis` returns nil, history is loaded before `spawn_server` is called and passed in `initial_state`.

History is only loaded on spawn (cold start). Live Jido state is authoritative while the process runs.

---

## Steps

### RED Phase — failing tests first

- [ ] **Step 1 — `Executor` scope tests**
  - Module: `Zaq.Agent.Executor`
  - Tests to write:
    - [ ] `derive_scope/1 returns "mattermost-2" for person_id=2, provider=:mattermost`
    - [ ] `derive_scope/1 returns "email_imap-5" for person_id=5, provider=:"email:imap"`
    - [ ] `derive_scope/1 returns "bo-<session>" for person_id=nil, provider=:web, metadata has session_id`
    - [ ] `derive_scope/1 returns "anonymous" when person_id nil and no session_id`
    - [ ] `ensure_agent_server/3 passes "AgentName:mattermost-2" as server_id to ensure_server_by_id`

- [ ] **Step 2 — `ConfiguredAgent` changeset tests**
  - Module: `Zaq.Agent.ConfiguredAgent`
  - Tests to write:
    - [ ] `changeset/2 accepts idle_time_seconds as positive integer`
    - [ ] `changeset/2 accepts memory_context_max_size as positive integer`
    - [ ] `changeset/2 accepts nil for both fields`

- [ ] **Step 3 — `ServerManager` idle TTL tests**
  - Module: `Zaq.Agent.ServerManager`
  - Tests to write:
    - [ ] `ensure_server_by_id/2 schedules idle timer using configured_agent.idle_time_seconds`
    - [ ] `ensure_server_by_id/2 uses system default when idle_time_seconds is nil`
    - [ ] `ensure_server_by_id/2 cancels and resets timer on repeated call before expiry`
    - [ ] `handle_info :expire_server removes entry from state.timers`
    - [ ] `stop_server/1 cancels timer and removes from state.timers`

- [ ] **Step 4 — `HistoryLoader` tests**
  - Module: `Zaq.Agent.HistoryLoader` (new)
  - Tests to write:
    - [ ] `load/3 returns an empty %Jido.AI.Context{} when no conversations exist`
    - [ ] `load/3 returns a context whose entries are truncated to stay within max_tokens`
    - [ ] `load/3 context.entries are newest-first (Jido.AI.Context.append prepends); to_messages/1 reversal produces chronological LLM messages`
    - [ ] `load/3 maps "user" DB role to Entry with role: :user`
    - [ ] `load/3 maps "assistant" DB role to Entry with role: :assistant`
    - [ ] `load/3 uses default 5000 tokens when max_tokens not supplied`
    - [ ] `load/3 returns context with empty entries for nil person_id`

- [ ] **Step 5 — `ServerManager` history-on-restart tests**
  - Tests to write:
    - [ ] `ensure_server_by_id/3 injects loaded context into initial_state[:context] when process is dead`
    - [ ] `ensure_server_by_id/3 does NOT call HistoryLoader when process already alive`

---

### GREEN Phase — implementation

- [ ] **Step 6 — `Executor`: channel-aware `derive_scope/1`**
  - Add private `normalize_provider/1` helper.
  - Rewrite scope clauses:
    - non-nil `person_id`: `"#{normalize_provider(provider)}-#{person_id}"`
    - nil `person_id` + BO: `"bo-#{session_id}"`
    - fallback: `"anonymous"`
  - No changes to `ensure_agent_server/3` — server ID format is already `"#{name}:#{scope}"`.
  - Module: `Zaq.Agent.Executor`
  - Temporary code? No
  - Coverage target: `>= 95%`

- [ ] **Step 7 — Migration + `ConfiguredAgent` schema**
  - `mix ecto.gen.migration add_idle_time_and_memory_context_to_configured_agents`
  - Adds `idle_time_seconds :integer, null: true` and `memory_context_max_size :integer, null: true`.
  - `ConfiguredAgent`: add both fields to schema and to `@optional_fields` in changeset.
  - Module: `Zaq.Agent.ConfiguredAgent`
  - Temporary code? No
  - Coverage target: `>= 95%`

- [x] **Step 7b — BO UI: expose `idle_time_seconds` and `memory_context_max_size` in agent form**
  - Files: `lib/zaq_web/live/bo/ai/agents_live.html.heex`, `lib/zaq_web/live/bo/ai/agents_live.ex`
  - In the template, add a new `grid grid-cols-1 gap-3 md:grid-cols-2` row **between** the "Advanced Options" block and the boolean toggles block:
    - Left cell — **Idle Timeout (seconds)** number input, `name="configured_agent[idle_time_seconds]"`, `value={@form[:idle_time_seconds].value || ""}`, `placeholder="Default: 1800"`. Helper text: `"Leave blank to use the system default (30 min)."`.
    - Right cell — **Memory context size (tokens)** number input, `name="configured_agent[memory_context_max_size]"`, `value={@form[:memory_context_max_size].value || ""}`, `placeholder="Default: 5000"`. Helper text: `"Max conversation history tokens loaded on process restart."`.
    - Both cells render `error_messages(@changeset, :idle_time_seconds)` / `error_messages(@changeset, :memory_context_max_size)` in the same pattern as existing fields.
  - No changes needed in `agents_live.ex`: both fields are plain integers, `parse_form_attrs/1` passes raw attrs to the changeset and Ecto handles the integer cast. Verify the `"validate"` and `"save"` handlers don't need special handling (they don't — numeric fields cast cleanly via `cast/4`).
  - Module: `ZaqWeb.Live.BO.AI.AgentsLive`
  - Temporary code? No
  - Tests to add before implementation:
    - [ ] LiveView test: `save event with idle_time_seconds=3600 persists value`
    - [ ] LiveView test: `save event with idle_time_seconds="" persists nil`
    - [ ] LiveView test: `save event with memory_context_max_size=2000 persists value`
    - [ ] LiveView test: form renders both inputs when editing an existing agent
  - Coverage target: `>= 95%`

- [ ] **Step 8 — `ServerManager`: per-agent idle TTL**
  - Add `timers: %{}` to state in `init/1`.
  - Add private `schedule_idle_timer/3 (state, server_id, configured_agent)`:
    - Cancels existing timer if present.
    - Computes TTL from `configured_agent.idle_time_seconds` or system default.
    - Sends `Process.send_after(self(), {:expire_server, server_id}, ttl_ms)`.
    - Returns updated state.
  - Call `schedule_idle_timer` at the end of both `handle_call({:ensure_server_by_id, ...})` success branches (server already running AND newly spawned).
  - Extend `handle_info({:expire_server, server_id})` to `Map.delete(state.timers, server_id)`.
  - Extend `handle_call({:stop_server_by_raw_id, server_id})` to cancel + delete timer.
  - Module: `Zaq.Agent.ServerManager`
  - Temporary code? No
  - Coverage target: `>= 95%`

- [ ] **Step 9 — `HistoryLoader`: DB→`Jido.AI.Context` conversion**
  - New module `Zaq.Agent.HistoryLoader`.
  - `load(person_id, channel_type, opts \\ []) :: Jido.AI.Context.t()`:
    - `max_tokens` opt, default `5_000`.
    - Returns an empty `%Jido.AI.Context{}` immediately if `person_id` is `nil`.
    - Queries `Conversations` for active convos matching `person_id` + `channel_type`, `order_by: [desc: inserted_at]`.
    - Preloads messages for those convos ordered `desc: inserted_at`, accumulates until token budget exhausted (using `TokenEstimator.estimate/1` per message).
    - **Reverses the accumulated list to chronological order (oldest first) before appending** — `Jido.AI.Context.append` prepends each entry (`[entry | entries]`), so to get the right LLM order after `to_messages/1` reversal, we must feed messages oldest-first. Verified: `to_messages/1` calls `Enum.reverse(thread.entries)` to produce chronological order.
    - Builds a `%Jido.AI.Context{}` by calling `Jido.AI.Context.new()` then appending entries in chronological order:
      - DB role `"user"` → `Context.append_user(ctx, content)`
      - DB role `"assistant"` → `Context.append_assistant(ctx, content)`
    - Returns the `%Jido.AI.Context{}` struct.
  - **Do NOT use `History.build/1` or `History.entry_key/2`** — those are for the non-Jido retrieval path only (see `retrieval.ex` and `chat_live.ex`). `Jido.AI.Context` uses `Entry` structs, not `ReqLLM.Message`.
  - `Zaq.Agent.History` is NOT deprecated — it remains the correct tool for `retrieval.ex` and the BO `chat_live.ex` WebBridge path.
  - Uses `Repo` directly — read-only internal query; no NodeRouter call needed since history loading is inside the agent node.
  - Module: `Zaq.Agent.HistoryLoader` (new file)
  - Temporary code? No
  - Coverage target: `>= 95%`

- [ ] **Step 10 — `ServerManager`: inject context on cold spawn**
  - Change public signature: `ensure_server_by_id(configured_agent, server_id, spawn_opts \\ %{})`.
  - `spawn_opts` carries `%{person_id: integer | nil, channel_type: string | nil}`.
  - GenServer call message: `{:ensure_server_by_id, configured_agent, server_id, spawn_opts}`.
  - In the handler, when `safe_whereis` returns nil:
    - Call `HistoryLoader.load(person_id, channel_type, max_tokens: configured_agent.memory_context_max_size || 5_000)`.
    - Merge the returned `%Jido.AI.Context{}` into `initial_state` as the `:context` key: `Map.put(initial_state, :context, context)`.
    - **Key**: the Jido ReAct strategy's `init/1` reads `agent.state.context` and calls `AIContext.coerce/1` on it. Passing it under `:context` in `initial_state` (which merges into `agent.state`) is the correct and only supported injection point. Do not use `:history`.
  - Update `Executor.ensure_agent_server/3` to pass `%{person_id: incoming.person_id, channel_type: normalize_channel_type(incoming.provider)}` as `spawn_opts`.
  - Module: `Zaq.Agent.ServerManager`, `Zaq.Agent.Executor`
  - Temporary code? No
  - Coverage target: `>= 95%`

- [ ] **Step 12 — `mix precommit` + coverage review**

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Include provider in `derive_scope/1` rather than in a separate arg | `derive_scope` is the single canonical scope source; adding a second parallel derivation path would split responsibility. Embedding provider in scope is minimal and self-contained. | 2026-04-27 |
| `:web` provider normalized to `"bo"` | `:web` is an internal provider atom, not user-facing. `"bo"` matches the existing `"bo"` language used throughout the codebase for the back-office channel. | 2026-04-27 |
| `:"email:imap"` normalized to `"email_imap"` (colon → underscore) | Colons in server IDs would conflict with the `":"` separator already used between agent name and scope. Underscores are safe in all Jido registry key contexts. | 2026-04-27 |
| Timer cancel+reschedule on every `ensure_server_by_id` call | Each call represents an inbound message. Resetting the timer on activity gives "idle since last message" semantics, which is the user's intent. A single one-shot timer scheduled only at spawn would not reset on activity. | 2026-04-27 |
| `HistoryLoader` as a new module (not added to `Conversations` context) | `Conversations` owns conversation CRUD. Loading history specifically for agent memory initialization is an agent-domain concern. A separate module keeps responsibilities clear and the agent domain self-contained. | 2026-04-27 |
| History only injected on cold spawn, not on every call | Jido accumulates history in process state as the conversation progresses. Injecting from DB on every call would overwrite live in-memory turns. DB is authoritative only when the process is cold. | 2026-04-27 |
| `spawn_opts` as a map, not expanded keyword args | `ensure_server_by_id/2` already has a two-arg public API. Adding a third optional map arg is backward-compatible; keyword explosion would require callers to change. | 2026-04-27 |
| `memory_context_max_size` defaults to 5,000 in `HistoryLoader`, not in schema | Schema default of `nil` means "use system default" — a single default location (`HistoryLoader`) avoids dual-source-of-truth. | 2026-04-27 |
| Injection key is `:context`, not `:history` | Verified by reading `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex` `init/1`: it reads `agent.state.context` and calls `AIContext.coerce/1`. `initial_state` merges into `agent.state` via `Map.merge`. Passing `%{context: %Jido.AI.Context{}}` is the correct and only supported path. | 2026-04-27 |
| `HistoryLoader` returns `%Jido.AI.Context{}`, not a history map | `Jido.AI.Context.coerce/1` accepts a `%Jido.AI.Context{}` struct or a plain map with `:id` + `:entries`. It does NOT accept the `ReqLLM.Message` list that `History.build/1` produces. `HistoryLoader` builds the `Jido.AI.Context` directly using `Context.append_user/append_assistant`. | 2026-04-27 |
| `Zaq.Agent.History` is NOT deprecated | `History.entry_key/2` is used by `chat_live.ex` (WebBridge history map) and `History.build/1` is used by `retrieval.ex` (converts history map → `ReqLLM.Message` for the retrieval LLM call). Both are non-Jido paths. `HistoryLoader` is a completely separate module for the Jido agent cold-start path. | 2026-04-27 |
| `HistoryLoader` appends DB messages in chronological order | `Jido.AI.Context.append` prepends entries (`[entry | entries]`), making `entries` newest-first. `to_messages/1` calls `Enum.reverse(thread.entries)` to restore chronological order. Therefore `HistoryLoader` must call `append_user/append_assistant` oldest-first (reverse the desc-ordered DB accumulation before appending). | 2026-04-27 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| ~~Confirm Jido `initial_state.history` key is the correct injection point~~ | ~~Jad / Jido docs~~ | resolved — injection key is `:context`; verified via `deps/jido_ai/lib/jido_ai/reasoning/react/strategy.ex` `init/1` |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] `derive_scope/1` includes provider in all scope strings
- [ ] Server IDs are `"AgentName:provider-person_id"` format throughout
- [ ] `configured_agents` migration applied cleanly
- [ ] Idle timer resets on every incoming message
- [ ] History injected as `initial_state[:context]` (`%Jido.AI.Context{}`) only on cold spawn
- [ ] Both new fields visible and editable in BO agent admin form
- [ ] Relevant docs updated
- [ ] Plan moved to `docs/exec-plans/completed/`
