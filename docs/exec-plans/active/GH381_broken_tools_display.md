# GH#381 — Display Saved Broken Tools for Safe Removal

## Problem

An agent stores tool references as `enabled_tool_keys: {:array, :string}`. When a
developer removes a tool from `Registry.@tools`, affected agents hit a deadlock:

1. **Changeset blocks** — `validate_tool_keys/1` rejects ghost keys → agent cannot be
   saved, renamed, or have its model changed.
2. **UI is blind** — `selected_tools_panel` only renders keys present in `@tools`, so
   ghost keys are invisible and cannot be removed.

---

## Step 1 — Backend: Unblock changeset + Registry helper

**Files:** `lib/zaq/agent/tools/registry.ex`, `lib/zaq/agent/configured_agent.ex`

**Changes:**
- `Registry.ghost_keys/1` — returns the subset of a key list not in `@tools`.
- `validate_tool_keys/1` — only errors on *newly-added* unknown keys; keys that already
  exist in `changeset.data.enabled_tool_keys` are allowed through so the agent stays
  editable.

**Tests (`test/zaq/agent/configured_agent_test.exs`):**
- Ghost key already in `data.enabled_tool_keys` → changeset valid
- Adding a brand-new unknown key → `enabled_tool_keys` error
- Removing a ghost key → changeset valid

**Status:** ✅ Done

---

## Step 2 — Frontend: Display ghost tools with visual indicator

**Files:** `lib/zaq_web/live/bo/ai/agents_live.ex`

**Changes:**
- `selected_tools_panel/1` builds a `tool_index` then maps each `selected_key` to either
  its known descriptor or a ghost descriptor
  `%{key: key, label: key, description: "This tool has been removed from the system.", ghost: true}`.
- Ghost rows render in red with a "Removed" badge; remove button works identically to
  valid tools (reuses existing `remove_tool` event).

**Tests (`test/zaq_web/live/bo/ai/agents_live_test.exs`):**
- Agent with ghost key → ghost row visible with "Removed" label
- Remove ghost tool → key disappears; agent saves successfully
- Agent with only valid tools → behaviour unchanged

**Status:** ✅ Done

---

## Definition of Done

- [ ] `mix precommit` passes
- [ ] Coverage ≥ 95% on touched files
- [ ] Ghost rows visible in BO with Removed badge
- [ ] Agent with ghost keys can be saved / ghost keys can be removed
