# Execution Plan: Delete Chat in BO

**Date:** 2026-05-07
**Author:** Jad
**Status:** `active`
**Related debt:** n/a
**PR(s):** TBD

---

## Goal

The "Clear chat" trash-icon button in the BO chat page only wipes frontend assigns — it never calls any context function, so the conversation stays in the database and the sidebar. This plan wires up a confirmation modal ("Are you sure you want to delete this chat?") that, on confirm, permanently deletes the conversation from the DB and removes it from the left sidebar.

---

## Context

Docs read before writing this plan:
- [x] `docs/architecture.md` (NodeRouter rules)
- [x] `docs/conventions.md`
- [x] `docs/services/engine.md` (conversations context)
- [x] Existing code reviewed:
  - `lib/zaq_web/live/bo/communication/chat_live.ex`
  - `lib/zaq_web/live/bo/communication/chat_live.html.heex`
  - `lib/zaq/engine/conversations.ex`

### Infrastructure Audit

- **Existing entry points:** `Zaq.Engine.Conversations.delete_conversation_by_id/1` already exists (line 153). `reload_sidebar_conversations/1` already exists in `chat_live.ex` (line 831). No new context functions needed.
- **`@moduledoc` read:**
  - `ChatLive` — "Back-office chat. Full-size chat interface with live status callbacks." Adding a delete event handler + confirmation state fits this responsibility.
  - `Zaq.Engine.Conversations` — "Context module for managing conversations, messages, ratings, and shares." `delete_conversation_by_id` already lives here; no changes needed to this module.
- **No parallel code path:** Reusing existing `delete_conversation_by_id` and `reload_sidebar_conversations`.
- **Provider/credential/URL logic:** n/a

---

## Approach

Add a `show_delete_confirm` boolean assign to `ChatLive`. The existing trash-icon "Clear chat" button is renamed to "Delete chat" and now fires `delete_chat_confirm`. That event opens the modal (guard: no-op if no active conversation). The modal has Cancel → `close_delete_modal` and Delete → `delete_chat`. The `delete_chat` handler calls `NodeRouter.call(:engine, Conversations, :delete_conversation_by_id, [id])`, clears conversation state, and reloads the sidebar.

The `+` new-chat button in the sidebar header is renamed from `clear_chat` → `new_chat` (same logic, cleaner semantics).

---

## Steps

- [ ] **Step 1:** Add `show_delete_confirm` assign and rename `clear_chat` → `new_chat`
  - Module placement check: `ChatLive` — @moduledoc covers back-office chat state management. ✓
  - Temporary code? No
  - Tests to add before implementation:
    - [ ] Integration: `handle_event("new_chat", ...)` clears state and sets `current_conversation_id: nil`
    - [ ] Branch/path: called with and without an active conversation
    - [ ] Permission/security paths: n/a (no permission filtering here)
    - [ ] Edge external API mocks: none
  - Coverage target: `>= 95%`

- [ ] **Step 2:** Add `delete_chat_confirm`, `close_delete_modal`, and `delete_chat` event handlers
  - Module placement check: `ChatLive` — event handlers for BO chat UI. ✓
  - Temporary code? No
  - Tests to add before implementation:
    - [ ] Integration: `delete_chat_confirm` with `current_conversation_id: nil` → `show_delete_confirm` stays false
    - [ ] Integration: `delete_chat_confirm` with active conversation → `show_delete_confirm: true`
    - [ ] Integration: `close_delete_modal` → `show_delete_confirm: false`
    - [ ] Integration: `delete_chat` → conversation deleted from DB, sidebar reloaded, state cleared, modal closed
    - [ ] Branch/path: `delete_chat` called when conversation no longer exists (already deleted) — must not crash
    - [ ] Permission/security paths: n/a
    - [ ] Edge external API mocks: none (NodeRouter.call is real in integration tests)
  - Coverage target: `>= 95%`

- [ ] **Step 3:** Add confirmation modal to `chat_live.html.heex` and update button bindings
  - Module placement check: template change only — no module responsibility question
  - Temporary code? No
  - Tests to add before implementation:
    - [ ] LiveView test: modal renders when `show_delete_confirm: true`
    - [ ] LiveView test: Cancel button fires `close_delete_modal`
    - [ ] LiveView test: Delete button fires `delete_chat`
    - [ ] LiveView test: modal absent when `show_delete_confirm: false`
  - Coverage target: `>= 95%`

---

## Decisions Log

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Rename `clear_chat` → `new_chat` for `+` button | `clear_chat` is ambiguous; `new_chat` reflects intent and avoids confusion with `delete_chat` | 2026-05-07 |
| Guard `delete_chat_confirm` when no active conversation | Trash icon is visible even with no active chat loaded; no-op prevents confusing empty-state deletes | 2026-05-07 |
| No new context function needed | `delete_conversation_by_id/1` already exists in `Conversations` | 2026-05-07 |

---

## Blockers

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| None    |       |        |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
