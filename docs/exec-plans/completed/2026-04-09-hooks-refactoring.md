# Execution Plan: Hooks Refactoring and Documentation

**Date:** 2026-04-09
**Author:** Claude
**Status:** `completed`
**Related issue:** www-zaq-ai/zaq#140
**PR(s):** TBD

---

## Goal

Refactor the ZAQ hook system to remove positional `before`/`after` naming from both
dispatch functions and event atoms, replacing it with semantic names that reflect
execution mode (sync vs async). Add centralised event documentation and a
compile-time/mix-task verification that every dispatched event is documented and
dispatched from exactly one place.

---

## Context

Docs and code reviewed:

- [x] `lib/zaq/hooks.ex` — `dispatch_before/3`, `dispatch_after/3`
- [x] `lib/zaq/hooks/hook.ex` — Hook struct (modes: `:sync`, `:async`)
- [x] `lib/zaq/hooks/handler.ex` — Behaviour + existing event docs
- [x] `lib/zaq/hooks/registry.ex` — ETS-backed registry
- [x] `lib/zaq/agent/pipeline.ex` — Agent pipeline dispatch sites
- [x] `lib/zaq/engine/conversations.ex` — `:feedback_provided` dispatch site
- [x] `lib/zaq/ingestion/chunk.ex` — `:after_embedding_reset` dispatch site
- [x] `test/zaq/hooks_test.exs` — Full test suite

---

## Current State

### Dispatch functions
| Current name | Mode | Semantics |
|---|---|---|
| `dispatch_before/3` | sync chain | Can mutate payload; caller receives `{:ok, payload}` or `{:halt, payload}` |
| `dispatch_after/3` | sync observer + async | Always returns `:ok`; fire-and-forget |

### Event atoms
| Current atom | Dispatch fn | Location |
|---|---|---|
| `:before_retrieval` | `dispatch_before` | `Zaq.Agent.Pipeline` |
| `:after_retrieval` | `dispatch_after` | `Zaq.Agent.Pipeline` |
| `:before_answering` | `dispatch_before` | `Zaq.Agent.Pipeline` |
| `:after_answer_generated` | `dispatch_after` | `Zaq.Agent.Pipeline` |
| `:after_pipeline_complete` | `dispatch_after` | `Zaq.Agent.Pipeline` |
| `:feedback_provided` | `dispatch_after` | `Zaq.Engine.Conversations` |
| `:after_embedding_reset` | `dispatch_after` | `Zaq.Ingestion.Chunk` |

---

## Approach

### 1. Rename dispatch functions

Remove positional naming; express what the call does to the caller:

| Old | New | Rationale |
|---|---|---|
| `dispatch_before/3` | `dispatch_sync/3` | Runs sync intercepting chain; caller blocks and receives mutated payload |
| `dispatch_after/3` | `dispatch_async/3` | Notifies handlers fire-and-forget; caller always gets `:ok` immediately |

The function bodies are unchanged — only the public names change.

### 2. Rename event atoms

Strip positional `before_` / `after_` prefix. Where the event has a clear lifecycle
meaning the name becomes the lifecycle noun:

| Old atom | New atom | Notes |
|---|---|---|
| `:before_retrieval` | `:retrieval` | sync — mutate query before retrieval step |
| `:after_retrieval` | `:retrieval_complete` | async — notify with retrieval results |
| `:before_answering` | `:answering` | sync — mutate retrieval payload before LLM |
| `:after_answer_generated` | `:answer_generated` | async — notify with raw LLM answer |
| `:after_pipeline_complete` | `:pipeline_complete` | async — notify with final pipeline result |
| `:feedback_provided` | `:feedback_provided` | already semantic, keep as-is |
| `:after_embedding_reset` | `:embedding_reset` | async — notify after embedding table reset |

### 3. Centralise event documentation

Move/consolidate all event docs into `Zaq.Hooks` `@moduledoc`. The `Zaq.Hooks.Handler`
moduledoc currently holds the event catalogue — relocate it so the primary dispatch
module is the single source of truth. Keep `Handler` docs focused on the behaviour
contract only.

### 4. Add verification mix task

Create `lib/mix/tasks/hooks.verify.ex` implementing `Mix.Task` with task name
`hooks.verify`. The task:

1. Greps the compiled BEAM or source for all `dispatch_sync/dispatch_async` calls
   and extracts the event atom from each call site.
2. Reads the list of documented events from `Zaq.Hooks` module doc (or a
   `@documented_events` module attribute).
3. Asserts:
   - **Uniqueness**: each event atom appears in at most one call site.
   - **Coverage**: every dispatched event atom is present in the documented set.
4. Prints a pass/fail report; exits non-zero on failure.

Add `mix hooks.verify` to the `mix precommit` alias in `mix.exs`.

---

## Steps

- [x] **Step 1 — Rename dispatch functions**
  - In `lib/zaq/hooks.ex`: rename `dispatch_before/3` → `dispatch_sync/3` and
    `dispatch_after/3` → `dispatch_async/3`. Update `@spec`, `@doc`, and telemetry
    metadata strings (`:mode` values) accordingly.
  - Update all call sites: `lib/zaq/agent/pipeline.ex`,
    `lib/zaq/engine/conversations.ex`, `lib/zaq/ingestion/chunk.ex`.
  - Update `test/zaq/hooks_test.exs` to call new names.
  - Run `mix precommit`.

- [x] **Step 2 — Rename event atoms**
  - Replace all old event atoms at call sites and in tests per the table above.
  - Update `Hook.t()` docs in `lib/zaq/hooks/hook.ex` if it mentions event names.
  - Run `mix precommit`.

- [x] **Step 3 — Centralise documentation**
  - Move the event catalogue from `Zaq.Hooks.Handler` `@moduledoc` into
    `Zaq.Hooks` `@moduledoc` under a dedicated `## Events` section.
  - Add a `@documented_events` module attribute listing all event atoms (used by
    the verification task in Step 4).
  - Trim `Zaq.Hooks.Handler` `@moduledoc` to only describe the callback contract.
  - Update `docs/services/agent.md` references.
  - Run `mix precommit`.

- [x] **Step 4 — Add `mix hooks.verify` task**
  - Create `lib/mix/tasks/hooks.verify.ex`.
  - Implement source-scan approach: grep for `dispatch_sync(` and `dispatch_async(`
    across `lib/`, extract the first-argument atom literal.
  - Read `Zaq.Hooks.@documented_events` via a helper (or duplicate the atom list
    in the task source).
  - Enforce uniqueness and coverage; print actionable errors.
  - Add the task to the `precommit` alias in `mix.exs`.
  - Write tests for the task in `test/mix/tasks/hooks_verify_test.exs`.
  - Run `mix precommit`.

- [ ] **Step 5 — Final validation & PR**
  - Run full test suite: `mix test`.
  - Run `mix hooks.verify` to confirm it passes on the refactored codebase.
  - Open PR against `main`, close issue #140.
  - Move this plan to `docs/exec-plans/completed/`.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| `dispatch_sync` / `dispatch_async` over `dispatch_intercepting` / `dispatch_notify` | Shorter, directly mirrors the Hook `:mode` field values (`:sync` / `:async`) | 2026-04-09 |
| Keep `:feedback_provided` unchanged | Already semantic; no positional prefix to remove | 2026-04-09 |
| Event docs live in `Zaq.Hooks`, not `Zaq.Hooks.Handler` | Dispatch module is the natural entry point for callers; handler implementors read `Zaq.Hooks` first | 2026-04-09 |
| Mix task (source scan) over Credo custom check | Simpler to implement, no Credo macro complexity; can still gate CI via `mix precommit` | 2026-04-09 |

---

## Blockers

None currently.

---

## Definition of Done

- [ ] All steps above completed
- [ ] `dispatch_before` / `dispatch_after` names no longer exist in the codebase
- [ ] No event atom contains `before_` or `after_` prefix
- [ ] All events documented under `Zaq.Hooks` `@moduledoc` in a single `## Events` section
- [ ] `mix hooks.verify` passes and is wired into `mix precommit`
- [ ] Tests written and passing (`mix test`)
- [ ] `mix precommit` passes
- [ ] PR opened and issue #140 closed
- [ ] Plan moved to `docs/exec-plans/completed/`
