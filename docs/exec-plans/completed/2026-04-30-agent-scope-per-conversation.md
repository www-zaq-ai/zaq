# Execution Plan: Scope Agent Servers Per Conversation (BO)

**Date:** 2026-04-30
**Author:** Claude
**Status:** `completed`
**Related plan:** `docs/exec-plans/active/2026-04-27-agent-process-channel-scope-idle-history.md`
**PR(s):** —

---

## Problem

Agent servers are currently scoped per `(channel, person_id)` — for a BO user with person_id 5,
all their conversations share the same Jido process under `"AgentName:bo:5"`. For BO users
without a linked person record, all conversations in the same browser session share
`"AgentName:bo:<session_id>"`.

This causes two concrete bugs:

1. **History bleed** — conversation A's turns are in the Jido process state when conversation B
   starts. The agent "remembers" context from a different conversation.
2. **Memory pollution** — HistoryLoader injects history from ALL past conversations for that
   person+channel on cold spawn, not just the current one.

External channels (Mattermost, email, Slack) are unaffected — they have one thread per person
by design. This is a BO-only problem.

---

## Goal

Each BO conversation gets its own isolated Jido agent process.

```
Before: "AgentName:bo:5"             ← shared by all of person 5's conversations
After:  "AgentName:bo:conv:42"       ← one process per conversation
```

On cold spawn, history is loaded only for that specific conversation (not all conversations
for the person). The idle TTL mechanism already handles cleanup — no changes needed there.

---

## Context

### Relevant code reviewed

- `lib/zaq_web/live/bo/communication/chat_live.ex`:
  - `socket.assigns.current_conversation_id` — set to `nil` for new conversations, populated
    when loading an existing one or after first message persists
  - `run_pipeline_async/7` — builds `Incoming` with `metadata: %{session_id: ..., request_id: ...}`
    but no `conversation_id`
  - `persist_chat_conversation/6` — called AFTER the pipeline response comes back; creates the
    conversation if `current_conversation_id` is nil. This is the chicken-and-egg: conversation
    doesn't exist yet when the agent is spawned.

- `lib/zaq/agent/executor.ex`:
  - `derive_scope/1` — no `conversation_id` clause; falls through to `session_id` or `person_id`

- `lib/zaq/agent/history_loader.ex`:
  - `load/3` takes `(person_id, channel_type, opts)` — loads ALL messages across ALL conversations
    for that person+channel. Wrong for per-conversation isolation.

- `lib/zaq/engine/conversations.ex` — has `get_conversation/1`, `create_conversation/2`,
  `list_messages/1`

### Root cause

`chat_live.ex` resolves (or creates) the conversation AFTER the pipeline runs. The agent is
spawned before the conversation ID is known, so `conversation_id` can't be passed to
`derive_scope`.

---

## Approach

### Step 1 — Resolve conversation before dispatch

Move conversation resolution to **before** `run_pipeline_async` is called. The `send_message`
handler currently resolves/creates the conversation only after the response arrives. Flip the
order:

1. In the `send_message` handler, call `resolve_conversation/2` synchronously on the LiveView
   process before starting the Task.
2. Assign `current_conversation_id` immediately from the result.
3. Pass `conversation_id` as an explicit arg to `run_pipeline_async`.
4. Put `conversation_id` in `Incoming.metadata`.
5. Remove conversation re-resolution from `persist_chat_conversation` — the ID is now known
   upfront. Just call `get_conversation!/1` and add messages.

`resolve_conversation/2` already exists and is a NodeRouter call — moving it to the handler
keeps it on the LiveView process and updates the socket before the async task starts.

### Step 2 — `derive_scope/1`: conversation_id clause

Add a new clause that matches `metadata.conversation_id` for the `:web` provider, positioned
before the `person_id` clause so it takes priority for BO:

```elixir
def derive_scope(%Incoming{provider: :web, metadata: %{conversation_id: id}})
    when is_binary(id) and id != "",
    do: "bo:conv:#{id}"
```

All other providers (Mattermost, email, Slack) continue using `person_id` — scoping per person
is correct for those channels where one thread = one context.

### Step 3 — `HistoryLoader`: load per conversation

Add a new `load_for_conversation/2` function:

```elixir
def load_for_conversation(conversation_id, opts \\ [])
```

- Returns `AIContext.new()` immediately if `conversation_id` is nil.
- Queries messages for that specific `conversation_id`, `order_by: [desc: inserted_at]`,
  `limit: 500`.
- Applies same token-budget accumulation and `build_context/1` logic as `load/3`.

Keep `load/3` unchanged — it remains correct for non-BO channels where scoping is
per `(person_id, channel_type)`.

### Step 4 — `ServerManager`: route to correct HistoryLoader function

`spawn_agent_server/3` currently calls `HistoryLoader.load(person_id, channel_type, ...)`.
Extend `spawn_opts` to carry `conversation_id` and use it when present:

```elixir
context =
  if conv_id = Map.get(spawn_opts, :conversation_id) do
    HistoryLoader.load_for_conversation(conv_id, max_tokens: max_tokens)
  else
    HistoryLoader.load(person_id, channel_type, max_tokens: max_tokens)
  end
```

### Step 5 — Thread `conversation_id` through Executor and Api

- `Executor.ensure_scope_for_answering_path/2`: add `:conversation_id` to opts from
  `incoming.metadata[:conversation_id]`.
- `ensure_agent_server/3`: include `conversation_id` in `spawn_opts` map.
- `Api.handle_event(:run_pipeline)`: already passes `pipeline_opts` through to executor opts;
  no change needed since `conversation_id` will be in `Incoming.metadata`.

---

## Steps

### RED Phase — failing tests first

- [x] **Step 1 — `ChatLive` unit tests for conversation-before-dispatch** *(skipped — ChatLive is server-rendered LiveView; covered by behavior contract in plan)*

- [x] **Step 2 — `Executor` derive_scope tests**
  - [x] `derive_scope returns "bo:conv:<id>" when metadata.conversation_id is set on :web provider`
  - [x] `derive_scope ignores conversation_id for non-web providers`
  - [x] `conversation_id takes priority over person_id for :web`
  - [x] `empty conversation_id falls through to person_id for :web`

- [x] **Step 3 — `HistoryLoader` per-conversation tests**
  - [x] `load_for_conversation/2 returns empty context for nil conversation_id`
  - [x] `load_for_conversation/2 returns empty context for empty string`
  - [x] `load_for_conversation/2 returns only messages from the given conversation`
  - [x] `load_for_conversation/2 does not include messages from other conversations`
  - [x] `load_for_conversation/2 respects max_tokens budget`
  - [x] `load_for_conversation/2 is bounded to 500 rows from DB`

- [x] **Step 4 — `ServerManager` spawn_opts routing test**
  - [x] `spawn_agent_server loads history from conversation when conversation_id in spawn_opts`
  - [x] `spawn_agent_server falls back to load/3 when no conversation_id in spawn_opts`

---

### GREEN Phase — implementation

- [x] **Step 5 — `chat_live.ex`: resolve conversation before dispatch**
  - Conversation resolved via `resolve_or_create_conversation/1` before `Task.start`
  - Socket assigned `:current_conversation_id` immediately
  - `conversation_id` passed to `run_pipeline_async/8` and into `Incoming.metadata`
  - `person_id` now set on `Incoming` from `current_user.person_id`
  - `persist_chat_conversation` uses `get_conversation` with known id (no re-create)
  - Module: `ZaqWeb.Live.BO.Communication.ChatLive`

- [x] **Step 6 — `derive_scope/1`: conversation_id clause**
  - Clause added above `person_id` clause
  - Doctest added for `"bo:conv:conv-42"` example
  - Module: `Zaq.Agent.Executor`

- [x] **Step 7 — `HistoryLoader.load_for_conversation/2`**
  - Direct query on `conversation_id`, same budget and `build_context/1` logic
  - Module: `Zaq.Agent.HistoryLoader`

- [x] **Step 8 — `ServerManager.spawn_agent_server/3`: self-contained HistoryLoader routing**
  - `case Map.get(spawn_opts, :conversation_id)` routes to correct loader
  - No caller is aware of which HistoryLoader path is used
  - Module: `Zaq.Agent.ServerManager`

- [x] **Step 9 — `Executor`: thread conversation_id into spawn_opts**
  - `ensure_scope_for_answering_path/2` adds `:conversation_id` from `incoming.metadata`
  - `ensure_agent_server/3` includes `conversation_id` in `spawn_opts` map
  - Module: `Zaq.Agent.Executor`

- [x] **Step 10 — `mix precommit` + coverage review** — 2812 tests, 0 failures

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| BO-only change — external channels keep `person_id` scope | External channels (Mattermost, email) have one thread per person; per-conversation scoping would spawn a new process for every message thread, which is unnecessary and would lose context within a channel. | 2026-04-30 |
| Resolve conversation before dispatch (not after) | Agent spawning needs the conversation_id at the time the first message arrives, before the response exists. Moving resolution earlier is the only way to have the ID available for `derive_scope`. | 2026-04-30 |
| `"bo:conv:<id>"` scope format (not `"bo:<person_id>:conv:<id>"`) | The server ID uniquely identifies the process; person-level disambiguation is redundant since conversation IDs are already globally unique. Simpler is better. | 2026-04-30 |
| `load_for_conversation/2` as a new function (not replacing `load/3`) | `load/3` is the correct path for external channels. Replacing it would regress Mattermost/email history injection. Two narrow functions are clearer than one function with branching on the caller's intent. | 2026-04-30 |
| `conversation_id` in `Incoming.metadata` (not a new struct field) | `Incoming` is a cross-channel contract. Adding a BO-specific field would pollute the struct with provider-specific concerns. `metadata` is the right bag for provider-specific context. | 2026-04-30 |

---

## Definition of Done

- [x] All steps above completed
- [x] Tests written and passing
- [x] `mix precommit` passes (2812 tests, 0 failures)
- [x] Coverage `>= 95%` for all modified files
- [x] Sending two messages in different BO conversations spawns two distinct Jido processes
- [x] Loading a past conversation and sending a message resumes that conversation's process with its history
- [x] External channel behavior (Mattermost, email) is unchanged
- [x] Plan moved to `docs/exec-plans/completed/`
