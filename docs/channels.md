# Channels Service

## Overview

The Channels service provides shared infrastructure for ZAQ's communication adapters.
Channel adapters are split into two concerns:

- **Ingestion channels** — document sources (Google Drive, SharePoint, ...) that feed the knowledge base
- **Retrieval channels** — messaging platforms (Mattermost, Slack, Email, ...) that receive user questions and return answers

Adapter lifecycle is owned by the **Engine** service, not the Channels service.
The Channels service only provides shared infrastructure (`PendingQuestions`) and
the `ChannelConfig` schema.

---

## Architecture

```
Zaq.Engine.Supervisor
  ├── Zaq.Engine.IngestionSupervisor     ← loads ingestion configs from DB, starts adapters
  │     └── Zaq.Channels.Ingestion.*    ← e.g. GoogleDrive, SharePoint (not yet implemented)
  └── Zaq.Engine.RetrievalSupervisor    ← loads retrieval configs from DB, starts adapters
        └── Zaq.Channels.Retrieval.Mattermost  ← Fresh WebSocket client
              ↕ WebSocket (/api/v4/websocket)
              Mattermost Server

Zaq.Channels.Supervisor
  └── Zaq.Channels.PendingQuestions     ← shared OTP Agent (used by retrieval adapters)
```

---

## Behaviour Contracts (owned by Engine)

### Ingestion Channel (`Zaq.Engine.IngestionChannel`)
- Defines the contract all ingestion adapters must implement
- Callbacks: `connect/1`, `disconnect/1`, `list_documents/1`, `fetch_document/2`
- Optional callbacks: `schedule_sync/1` (polling), `handle_event/2` (webhook)

### Retrieval Channel (`Zaq.Engine.RetrievalChannel`)
- Defines the contract all retrieval adapters must implement
- Callbacks: `connect/1`, `disconnect/1`, `send_message/3`, `handle_event/1`, `forward_to_engine/1`

---

## What's Done

### Channel Config (`Zaq.Channels.ChannelConfig`)
- Ecto schema backed by `channel_configs` DB table
- Fields: `name`, `provider`, `kind`, `url`, `token`, `enabled`
- `kind` — `:ingestion` or `:retrieval`, determines which supervisor manages the adapter
- `get_by_provider/1` — fetches enabled config for a provider
- `list_enabled_by_kind/2` — fetches enabled configs for a given kind, filtered to known providers (used by Engine supervisors)
- `test_connection/2` — sends a test message to verify connectivity
- Config is loaded from DB at runtime (not from env vars)

### Mattermost Retrieval Adapter (`Zaq.Channels.Retrieval.Mattermost`)
- Implements `Zaq.Engine.RetrievalChannel` behaviour
- Uses `Fresh` library for WebSocket connection
- Auto-reconnects on disconnect (returns `:reconnect` from `handle_disconnect`)
- Ignores messages from `@zaq` bot to prevent self-reply loops
- Routes thread replies to `PendingQuestions.check_reply/1`
- Routes new messages to `forward_to_engine/1` (currently logs only — Engine routing pending)
- Auth via Bearer token in WebSocket headers

### Mattermost HTTP API (`Zaq.Channels.Retrieval.Mattermost.API`)
- `send_message/3` — posts a message to a channel with optional `thread_id` (loads config from DB)
- `send_message/4` — posts using explicit config (for testing / direct calls)
- `send_typing/2` — sends typing indicator before responding (1000ms delay)
- `clear_channel/1` — deletes all posts in a channel (dev/test utility)
- Uses `HTTPoison` for HTTP calls

### Mattermost Event Parser (`Zaq.Channels.Retrieval.Mattermost.EventParser`)
- Parses raw Mattermost WebSocket JSON events into `%EventParser.Post{}` structs
- Fields: `id`, `message`, `user_id`, `channel_id`, `root_id`, `sender_name`, `channel_type`, `channel_name`, `create_at`
- Returns `{:unknown, event_type}` for unhandled event types

### Pending Questions (`Zaq.Channels.PendingQuestions`)
- OTP Agent tracking questions awaiting human answers in Mattermost threads
- State: `%{post_id => %{bot_user_id: string, callback: fun}}`
- `ask/5` — sends a question via `send_fn`, registers callback keyed by post ID
- `check_reply/1` — matches thread replies to pending questions, fires callback, clears entry
- Bot's own replies are ignored (matched by `bot_user_id`)
- `pending/0` — returns full state (for debugging)

---

## Files

```
lib/zaq/channels/
├── channel_config.ex                         # Ecto schema for channel configurations
├── pending_questions.ex                      # OTP Agent tracking unanswered questions
├── supervisor.ex                             # Starts PendingQuestions only
├── ingestion/                                # Ingestion adapter implementations (not yet implemented)
└── retrieval/
    ├── mattermost.ex                         # Fresh WebSocket client (RetrievalChannel impl)
    └── mattermost/
        ├── api.ex                            # HTTP client for Mattermost REST API
        └── event_parser.ex                   # Parses raw WS events → Post structs

lib/zaq/engine/
├── ingestion_channel.ex                      # Behaviour contract for ingestion adapters
├── retrieval_channel.ex                      # Behaviour contract for retrieval adapters
├── ingestion_supervisor.ex                   # Dynamically starts ingestion adapters from DB
├── retrieval_supervisor.ex                   # Dynamically starts retrieval adapters from DB
└── supervisor.ex                             # Top-level Engine supervisor
```

---

## Key Design Decisions

- **Engine owns the contracts** — `Zaq.Engine.IngestionChannel` and `Zaq.Engine.RetrievalChannel`
  define the adapter interfaces; channels depend on Engine, not the other way around
- **Engine owns the lifecycle** — `IngestionSupervisor` and `RetrievalSupervisor` start adapters
  dynamically based on DB configs; `Zaq.Channels.Supervisor` only manages shared infrastructure
- **Config from DB, not env** — channel configs are managed via BO, not environment variables
- **Graceful no-config startup** — if no configs are found, supervisors start empty (no crash)
- **Fresh for WebSocket** — uses the `Fresh` library, not Phoenix channels
- **kind field on ChannelConfig** — separates ingestion and retrieval configs at the DB level;
  defaults to `"retrieval"` for existing records
- **`forward_to_engine/1` is a stub** — currently logs the event; real routing to Engine pending
- **Thread support** — `send_message/3` and `send_message/4` accept an optional `thread_id`;
  `nil` or `""` sends to the channel root

---

## What's Left

### Must Do
- [ ] Implement `forward_to_engine/1` — route incoming messages to the Agent pipeline via `NodeRouter`
- [ ] Connect channel responses back to Mattermost (answer → `API.send_message/3`)

### Should Do
- [ ] Slack retrieval adapter (`Zaq.Channels.Retrieval.Slack`)
- [ ] Email retrieval adapter (`Zaq.Channels.Retrieval.Email`)
- [ ] Google Drive ingestion adapter (`Zaq.Channels.Ingestion.GoogleDrive`)
- [ ] SharePoint ingestion adapter (`Zaq.Channels.Ingestion.SharePoint`)
- [ ] Reload retrieval supervisor when config changes in BO (currently requires restart)

### Nice to Have
- [ ] Teams adapter
- [ ] Channel-level rate limiting
- [ ] Message queue for outbound messages under load