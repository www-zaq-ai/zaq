# Channels Service

## Overview

The Channels service is the multi-channel communication adapter for ZAQ. It connects
to external messaging platforms, receives incoming messages, and routes them to the
agent pipeline. Currently supports Mattermost via WebSocket. Slack and Email are planned.

---

## Architecture

```
Zaq.Channels.Supervisor
  └── Zaq.Channels.Mattermost.Supervisor
        ├── Zaq.Channels.PendingQuestions   ← Agent tracking unanswered questions
        └── Zaq.Channels.Mattermost.Client  ← Fresh WebSocket client
              ↕ WebSocket (/api/v4/websocket)
              Mattermost Server
```

---

## What's Done

### Channel Behaviour (`Zaq.Channels.Channel`)
- Defines the contract all channel adapters must implement
- Callbacks: `connect/1`, `disconnect/1`, `send_message/3`, `handle_event/1`, `forward_to_engine/1`

### Channel Config (`Zaq.Channels.ChannelConfig`)
- Ecto schema backed by `channel_configs` DB table
- Single config per provider (`mattermost`, `slack`, `teams`) — enforced by unique constraint
- Fields: `name`, `provider`, `url`, `token`, `enabled`
- `get_by_provider/1` — fetches enabled config for a provider
- `test_connection/2` — sends a test message to verify connectivity
- Config is loaded from DB at runtime (not from env vars)

### Mattermost WebSocket Client (`Zaq.Channels.Mattermost.Client`)
- Uses `Fresh` library for WebSocket connection
- Implements `Zaq.Channels.Channel` behaviour
- Auto-reconnects on disconnect (returns `:reconnect` from `handle_disconnect`)
- Ignores messages from `@zaq` bot to prevent self-reply loops
- Routes thread replies to `PendingQuestions.check_reply/1`
- Routes new messages to `forward_to_engine/1` (currently logs only — engine not started)
- Auth via Bearer token in WebSocket headers

### Mattermost HTTP API (`Zaq.Channels.Mattermost.API`)
- `send_message/2` — posts a message to a channel (loads config from DB)
- `send_message/3` — posts using explicit config (for testing / direct calls)
- `send_typing/2` — sends typing indicator before responding (1000ms delay)
- `clear_channel/1` — deletes all posts in a channel (dev/test utility)
- Uses `HTTPoison` for HTTP calls

### Event Parser (`Zaq.Channels.Mattermost.EventParser`)
- Parses raw Mattermost WebSocket JSON events into `%EventParser.Post{}` structs
- Fields: `id`, `message`, `user_id`, `channel_id`, `root_id`, `sender_name`, `channel_type`, `channel_name`, `create_at`
- Returns `{:unknown, event_type}` for unhandled event types

### Pending Questions (`Zaq.Channels.PendingQuestions`)
- Agent (OTP) tracking questions awaiting human answers in Mattermost threads
- State: `%{post_id => %{bot_user_id: string, callback: fun}}`
- `ask/5` — sends a question via `send_fn`, registers callback keyed by post ID
- `check_reply/1` — matches thread replies to pending questions, fires callback, clears entry
- Bot's own replies are ignored (matched by `bot_user_id`)
- `pending/0` — returns full state (for debugging)

### Mattermost Supervisor (`Zaq.Channels.Mattermost.Supervisor`)
- Reads config from DB on init via `ChannelConfig.get_by_provider("mattermost")`
- If config missing → starts with empty children (no crash)
- If config present → starts `PendingQuestions` and `Mattermost.Client`
- WebSocket URI built by replacing `https://` → `wss://` and appending `/api/v4/websocket`

---

## Files

```
lib/zaq/channels/
├── channel.ex                        # Behaviour contract for channel adapters
├── channel_config.ex                 # Ecto schema for channel configurations
├── pending_questions.ex              # OTP Agent tracking unanswered questions
├── supervisor.ex                     # Top-level channels supervisor
└── mattermost/
    ├── api.ex                        # HTTP client for Mattermost REST API
    ├── client.ex                     # Fresh WebSocket client
    ├── event_parser.ex               # Parses raw WS events → Post structs
    └── supervisor.ex                 # Starts PendingQuestions + WS client
```

---

## Key Design Decisions

- **Config from DB, not env** — channel configs are managed via BO, not environment variables
- **Graceful no-config startup** — if Mattermost is not configured, supervisor starts empty (no crash)
- **Fresh for WebSocket** — uses the `Fresh` library, not Phoenix channels
- **Single config per provider** — enforced by DB unique constraint on `provider`
- **`forward_to_engine` is a stub** — currently logs the event; real routing to Engine is pending

---

## What's Left

### Must Do
- [ ] Implement `forward_to_engine/1` — route incoming messages to the Agent pipeline
- [ ] Connect channel responses back to Mattermost (answer → `API.send_message/2`)

### Should Do
- [ ] Slack adapter (behaviour + supervisor + API client)
- [ ] Email adapter (behaviour + supervisor + mailer)
- [ ] Reload Mattermost supervisor when config changes in BO (currently requires restart)

### Nice to Have
- [ ] Teams adapter
- [ ] Channel-level rate limiting
- [ ] Message queue for outbound messages under load