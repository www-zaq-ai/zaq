# Conversation Audit Trail — Implementation Summary

## Goal

Enable users to copy full debug logs from BO conversation history and share them for diagnostics. Every assistant response now stores a complete ordered trail of what happened: tool calls, LLM reasoning turns, and pipeline failures.

---

## What Was Built

### 1. Tool Result Context Enrichment

**Files:** `lib/zaq/agent/tools/list_knowledge_base_files.ex`, `lib/zaq/agent/tools/search_knowledge_base.ex`

Both tools now attach a `_context` map to every result (success and error):

```json
{
  "person_id": 25,
  "team_ids": [],
  "skip_permissions": true,
  "source_filter": []
}
```

This makes it possible to see exactly what permission scope was active when a tool ran.

---

### 2. LLM Turn Capture

**File:** `lib/zaq/agent/jido_telemetry_bridge.ex`

The telemetry bridge now tracks `llm.complete` and `llm.error` events in the same ETS trace table as tool calls. Each LLM turn produces an entry:

```json
{
  "type": "llm_turn",
  "timestamp": "2026-05-14T14:18:31Z",
  "input_tokens": 3389,
  "output_tokens": 33,
  "decision": "tool_use",
  "status": "ok"
}
```

---

### 3. Unified Steps Trail in Message Metadata

**File:** `lib/zaq/engine/conversations.ex`

Every saved assistant message now has two keys in `metadata`:

| Key | Contents |
|-----|----------|
| `tool_calls` | Tool call entries only (backward compatible — feeds the existing tool calls modal) |
| `steps` | All entries in chronological order: tool calls + LLM turns + pipeline failures |

---

### 4. Pipeline Failure Steps

**File:** `lib/zaq/agent/executor.ex`

When the executor pipeline fails at any stage, a `pipeline_failure` step is recorded in the message metadata:

```json
{
  "type": "pipeline_failure",
  "stage": "timeout",
  "reason": ":timeout",
  "timestamp": "2026-05-14T14:19:00Z",
  "context": {
    "person_id": 25,
    "team_ids": []
  }
}
```

Stages: `"timeout"`, `"agent_load"`, `"unknown"`.

---

### 5. Copy Logs Button in BO History

**Files:** `lib/zaq_web/components/chat_message.ex`, `lib/zaq_web/live/bo/communication/conversation_detail_live.ex`, `lib/zaq_web/live/bo/communication/conversation_detail_live.html.heex`

A file-icon button appears on assistant messages that have steps. Clicking it copies the full `steps` array as pretty-printed JSON to the clipboard.

The button only appears when `metadata["steps"]` is non-empty (i.e., the pipeline ran and recorded traces).

---

### 6. Tool Name Renamed

**Files:** `lib/zaq/agent/tools/list_knowledge_base_files.ex`, `lib/zaq/agent/tools/registry.ex`

| Before | After |
|--------|-------|
| `list_knowledge_base_files` | `knowledge_base_overview` |
| "List knowledge base files" | "Knowledge Base Overview" |

Description updated to be user-facing: explains what the tool does without technical jargon.

---

### 7. Migration Fixes

**Files:** `priv/repo/migrations/20260408000002_remove_role_sharing_from_docs_and_chunks.exs`, `priv/repo/migrations/20260408000004_add_team_id_index_to_document_permissions.exs`

Added `IF EXISTS` guards on column drops and `create_if_not_exists` on index creation so migrations are safe to re-run on environments with inconsistent schema state.

---

## How to Use

1. Send a message in any Zaq channel
2. Go to **BO → History** → open the conversation
3. Hover over an assistant message
4. Click the **file icon** button (between the tool calls ⓘ button and the copy button)
5. The full step log is now in your clipboard — paste it anywhere to share

### Example copied log

```json
[
  {
    "type": "tool_call",
    "tool_name": "knowledge_base_overview",
    "timestamp": "2026-05-14T14:18:31Z",
    "params": { "source_filter": [] },
    "response": { "total": 6, "ingested_count": 2, "..." },
    "response_time_ms": 10,
    "status": "ok"
  },
  {
    "type": "llm_turn",
    "timestamp": "2026-05-14T14:18:31Z",
    "input_tokens": 3389,
    "output_tokens": 33,
    "decision": null,
    "status": "ok"
  },
  {
    "type": "llm_turn",
    "timestamp": "2026-05-14T14:18:34Z",
    "input_tokens": 3654,
    "output_tokens": 36,
    "decision": null,
    "status": "ok"
  }
]
```

---

## Note on Existing Conversations

Messages saved **before** this feature was deployed will not have `metadata["steps"]` and will not show the copy logs button. Only new messages (after server restart with the updated code) will have the full trail.
