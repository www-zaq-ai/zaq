# Channels Service

## Overview

The Channels service provides transport and runtime infrastructure for communication adapters.

- **Ingestion channels** ingest external documents (Google Drive, SharePoint, etc.).
- **Retrieval channels** receive user messages and deliver ZAQ responses (Mattermost, Slack, Teams, Email, Telegram, Discord).

All channel delivery flows through canonical message payload structs (`Incoming` / `Outgoing`) defined in `lib/zaq/engine/messages/`. Nothing inside ZAQ depends on adapter-specific envelope types. For cross-node routing, payloads are wrapped in `%Zaq.Event{}`.

---

## Module Map

| Module | File | Role |
|---|---|---|
| `Zaq.Channels.Router` | `lib/zaq/channels/router.ex` | Stateless outbound router — public entrypoint |
| `Zaq.Channels.JidoChatBridge` | `lib/zaq/channels/jido_chat_bridge.ex` | Provider bridge for jido_chat adapters |
| `Zaq.Channels.JidoChatBridge.State` | `lib/zaq/channels/jido_chat_bridge/state.ex` | Per-bridge GenServer state holder |
| `Zaq.Channels.EmailBridge` | `lib/zaq/channels/email_bridge.ex` | Bridge for email (SMTP) delivery |
| `Zaq.Channels.WebBridge` | `lib/zaq/channels/web_bridge.ex` | Bridge for web/ChatLive sessions via PubSub |
| `Zaq.Channels.Supervisor` | `lib/zaq/channels/supervisor.ex` | DynamicSupervisor — process lifecycle |
| `Zaq.Channels.ChannelConfig` | `lib/zaq/channels/channel_config.ex` | Ecto schema — connector configs |
| `Zaq.Channels.RetrievalChannel` | `lib/zaq/channels/retrieval_channel.ex` | Ecto schema — per-channel subscriptions |
| `Zaq.Channels.MattermostAdmin` | `lib/zaq/channels/mattermost_admin.ex` | Admin helpers for Mattermost UI |
| `Zaq.Channels.SmtpHelpers` | `lib/zaq/channels/smtp_helpers.ex` | Internal SMTP settings key normalizer |
| `Zaq.Engine.Messages.Incoming` | `lib/zaq/engine/messages/incoming.ex` | Canonical inbound message struct |
| `Zaq.Engine.Messages.Outgoing` | `lib/zaq/engine/messages/outgoing.ex` | Canonical outbound message struct |

---

## Message Structs

### `Zaq.Engine.Messages.Incoming`

Canonical struct for all inbound messages crossing the adapter boundary. Every adapter must map its transport-specific payload to this struct before passing a message to any ZAQ component.

When routed across nodes, this payload is carried in `%Zaq.Event.request`.

```elixir
@enforce_keys [:content, :channel_id, :provider]

defstruct [
  :content,       # String — message text
  :channel_id,    # String — platform channel ID
  :author_id,     # String | nil
  :author_name,   # String | nil
  :thread_id,     # String | nil
  :message_id,    # String | nil
  :provider,      # atom | String — e.g. :mattermost, :web
  metadata: %{}
]
```

### `Zaq.Engine.Messages.Outgoing`

Canonical struct for all outbound messages. Produced by `Zaq.Agent.Pipeline.run/2` and by the Notification center. Delivered via `Zaq.Channels.Router.deliver/1`.

When routed across nodes, this payload is typically returned in `%Zaq.Event.response`.

```elixir
@enforce_keys [:body, :channel_id, :provider]

defstruct [
  :body,          # String — response text
  :channel_id,    # String
  :thread_id,     # String | nil
  :author_id,     # String | nil
  :author_name,   # String | nil
  :provider,      # atom | String
  :in_reply_to,   # String | nil — message_id being replied to
  metadata: %{}
]
```

`Outgoing.from_pipeline_result/2` builds an `%Outgoing{}` from an `%Incoming{}` and a pipeline result map, copying routing fields and merging metadata.

---

## Router

`Zaq.Channels.Router` is the stateless public entrypoint for all outbound operations. It resolves the correct bridge module from app config (by provider atom key), fetches connection details from the DB, and delegates to `bridge.send_reply/2`.

### Public API

| Function | Description |
|---|---|
| `deliver/1` | Delivers `%Outgoing{}` to the correct bridge |
| `send_typing/2` | Sends typing indicator through the provider bridge |
| `add_reaction/4` | Adds a reaction through the provider bridge |
| `remove_reaction/5` | Removes a reaction through the provider bridge |
| `subscribe_thread_reply/3` | Subscribes to thread replies via provider bridge |
| `unsubscribe_thread_reply/3` | Unsubscribes from thread replies via provider bridge |
| `sync_config_runtime/2` | Synchronizes runtime processes when a channel config changes |
| `test_connection/2` | Runs bridge-specific connection test |
| `bridge_for/1` | Returns the configured bridge module for a provider |

### Bridge resolution

Bridges are resolved from `Application.get_env(:zaq, :channels)` by provider atom key:

```elixir
# Example config shape
config :zaq, :channels, %{
  mattermost: %{bridge: Zaq.Channels.JidoChatBridge, adapter: ..., ingress_mode: :websocket},
  email:      %{bridge: Zaq.Channels.EmailBridge},
  web:        %{bridge: Zaq.Channels.WebBridge}
}
```

The string `"email:smtp"` is mapped to the `:email` key before lookup. For `:web`, connection details are always `%{}` — delivery is via PubSub only.

`sync_config_runtime/2` calls `bridge.start_runtime/1` or `bridge.stop_runtime/1` on the bridge if the function is exported. This is how the Supervisor delegates lifecycle to the bridge.

---

## Jido Chat Bridge

`Zaq.Channels.JidoChatBridge` is the provider-facing bridge for the `jido_chat` adapter family (Mattermost, Telegram, Discord, etc.).

### Bridge-Adapter Contract (mandatory)

- Bridge ingress callback name is standardized as `from_listener/3`.
- Bridges orchestrate only: convert to `%Incoming{}`, run pipeline, deliver `%Outgoing{}`, persist conversation.
- Adapters own transport runtime details: connection lifecycle, listener child specs, and transport parsing.
- Bridges must request runtime specs from adapters (for example `adapter.runtime_specs/3`) instead of building listener specs directly.
- Adapter-specific callback names (for example `from_imap_listener/3`) are not allowed in bridge public APIs.

### Ingress flow

1. The adapter listener calls `from_listener/3` (configured as `sink_mfa` target).
2. `from_listener/3` ensures the runtime is started and looks up the `State` pid.
3. `State.process_listener_payload/4` transforms the raw payload via `Jido.Chat.Adapter.transform_incoming/2`, annotates it with transport mode, and processes it through `Chat.process_message/5`.
4. The `Chat` handlers fire: `on_new_mention`, `on_new_message`, `on_subscribed_message`.
5. For qualifying messages, `handle_message_event/3` converts the `Chat.Incoming` to an `%Incoming{}` via `to_internal/2`, resolves the author's role IDs, runs the pipeline, and delivers the `%Outgoing{}` result.

### Outbound flow

Called by `Router.deliver/1`:

1. `send_reply/2` receives `%Outgoing{}` and connection details `%{url, token}`.
2. Resolves the adapter module for the provider.
3. Builds a `Jido.Chat.Thread` and calls `Chat.Thread.post/3`.
4. If `outgoing.metadata` contains an `"on_reply"` key, dispatches an Oban job for reply tracking (used by the Notification center).

### Thread watch management

- `subscribe_thread_reply/3` — starts a dedicated bridge runtime for `{channel_id, thread_id}` and calls `State.subscribe_thread/4`.
- `unsubscribe_thread_reply/3` — unsubscribes and stops the dedicated runtime.
- Thread bridge IDs are keyed `"#{channel_id}_#{thread_id}"`.

### Runtime lifecycle

- `start_runtime/1` — starts State + listener processes for a channel config.
- `stop_runtime/1` — stops them via the Supervisor.
- `runtime_specs/3` — returns `{state_child_spec, listener_specs}` for the Supervisor.

### Ingress modes

Configured per provider via `:ingress_mode` in app config. Supported values:

| Mode | Behavior |
|---|---|
| `:websocket` | Adapter starts a persistent WebSocket listener |
| `:gateway` | Adapter starts a gateway listener |
| `:polling` | Adapter starts a polling listener |
| Any other / `nil` | No listener started; ingress is push-only |

### Configurable modules (testability)

All cross-service calls are overridable via Application env:

| Key | Default |
|---|---|
| `:chat_bridge_pipeline_module` | `Zaq.Agent.Pipeline` |
| `:chat_bridge_router_module` | `Zaq.Channels.Router` |
| `:chat_bridge_conversations_module` | `Zaq.Engine.Conversations` |
| `:chat_bridge_accounts_module` | `Zaq.Accounts` |
| `:chat_bridge_permissions_module` | `Zaq.Accounts.Permissions` |
| `:pipeline_hooks_module` | `Zaq.Hooks` |

When using the real modules, cross-node calls route through `Zaq.NodeRouter`.
Prefer `NodeRouter.dispatch/1` with `%Zaq.Event{}`. `NodeRouter.call/4` remains temporary compatibility and is deprecated.

---

## Jido Chat Bridge State

`Zaq.Channels.JidoChatBridge.State` is a GenServer that owns one `%Jido.Chat{}` struct per `bridge_id`. All mutations are serialized through this process to prevent race conditions across concurrent ingress sources.

### State shape

```elixir
@type state :: %{
  bridge_id: String.t(),
  config:    map(),
  chat:      Chat.t()
}
```

### Public calls

| Function | Description |
|---|---|
| `process_listener_payload/4` | Transforms + processes an adapter payload (serialized, `:infinity` timeout) |
| `subscribe_thread/4` | Adds a thread key to `chat.subscriptions` |
| `unsubscribe_thread/4` | Removes a thread key from `chat.subscriptions` |
| `send_reply/3` | Delegates to `JidoChatBridge.do_send_reply/2` |
| `send_typing/4` | Delegates to `JidoChatBridge.send_typing/3` |
| `add_reaction/6` | Delegates to `JidoChatBridge.add_reaction/5` |
| `remove_reaction/6` | Delegates to `JidoChatBridge.remove_reaction/5` |
| `refresh_config/2` | Replaces config and rebuilds handlers, preserving runtime state |

### Config refresh

`refresh_config/2` rebuilds the `Chat` struct (handlers, adapter) from the new config while preserving `subscriptions`, `dedupe`, `dedupe_order`, `thread_state`, and `channel_state` from the running instance.

---

## Email Bridge

`Zaq.Channels.EmailBridge` delivers `%Outgoing{}` via SMTP using `Zaq.Engine.Notifications.EmailNotification`. Connection details are not required — SMTP settings are read from `channel_configs.settings` for provider `"email:smtp"`.

- `send_reply/2` — sends to `outgoing.channel_id` (the recipient address). Subject and html_body are read from `outgoing.metadata` (supports both atom and string keys).
- `from_listener/3` — generic sink callback for inbound email listeners; orchestration is bridge-owned.
- `to_internal/2` — resolves the provider adapter and delegates payload normalization to the adapter.
- `start_runtime/1` and `stop_runtime/1` — resolve adapter runtime specs and delegate runtime lifecycle to `Channels.Supervisor`.

### Email IMAP Adapter

`Zaq.Channels.EmailBridge.ImapAdapter` owns IMAP-specific behavior:

- Runtime model: one `Zaq.Channels.EmailBridge.ImapAdapter.Listener` GenServer per selected mailbox (`state_pid` is `nil` for this runtime).
- Config shape: reads IMAP values from top-level config and `settings["imap"]` (`url`, `username`, `token`/`password`, `port`, `ssl`, `ssl_depth`, `timeout`, `idle_timeout`, `poll_interval`, `mark_as_read`, `load_initial_unread`, `selected_mailboxes`).
- Mailbox selection: if `selected_mailboxes` is empty, runtime can start but no listener children are created, so no inbound messages are consumed.
- Lifecycle: listener boot is `:connect -> optional initial unread fetch -> IDLE`; each `:idle_notify` fetches unseen messages, dispatches sink callback, optionally marks as read, then re-enters IDLE.
- Error handling: connect/fetch/IDLE re-entry failures and IMAP client exits are logged, client state is cleared, and reconnect is scheduled with `poll_interval` fallback (`30_000ms` default).
- IDLE timeout: `idle_timeout` defaults to `1_500_000ms` (25 minutes) when missing/invalid and is reused for each IDLE re-entry.
- Security: IMAP auth uses stored connector credentials (encrypted `channel_configs.token`), TLS is on by default (`ssl != false`), and logs avoid credential values.
- Security: parser stores `incoming.metadata["email"]["html_body"]` as raw, untrusted email HTML for fidelity. Renderers must treat it as untrusted content and only display it through explicit sanitization or strict isolation/sandboxing.

#### Email Threading Semantics

- `thread_key`: stable conversation root key (`References` first id -> `In-Reply-To` -> `Message-ID`) used by `Conversations` for grouping.
- `thread_id`: nearest parent/current reply identity (`In-Reply-To` -> last `References` id -> `Message-ID`) kept in metadata for reply/header continuity.
- Parser stores both in `incoming.metadata["email"]`; conversation lookup prioritizes `thread_key`.

### SMTP Helpers (`Zaq.Channels.SmtpHelpers`)

Internal utility module used by the email bridge. Not part of the public API.

- `map_get/2` — looks up a settings key by string name, falling back to its atom equivalent. Handles the dual string/atom key formats that SMTP settings maps may contain (e.g., `"relay"` and `:relay` are both accepted).

---

## Web Bridge

`Zaq.Channels.WebBridge` serves the ChatLive web channel.

- `to_internal/2` — converts ChatLive form params to `%Incoming{provider: :web}`. Expects params keys `:content`, `:channel_id`, `:session_id`, `:request_id`.
- `send_reply/2` — broadcasts `{:pipeline_result, request_id, outgoing, user_content}` to the `"chat:<session_id>"` PubSub topic.
- `on_status_callback/2` — returns a callback that broadcasts `{:status_update, request_id, stage, message}` to the session topic for pipeline progress updates.

---

## Supervisor

`Zaq.Channels.Supervisor` is a `DynamicSupervisor` that manages bridge runtime processes.

### Process tracking

Runtime state is tracked per `bridge_id` in an ETS table (`:zaq_channels_listeners`):

```elixir
bridge_id => %{listener_pids: [pid], state_pid: pid | nil}
```

### Public API

| Function | Description |
|---|---|
| `start_runtime/3` | Starts State + listener children for a bridge ID |
| `stop_bridge_runtime/2` | Stops all children and removes ETS entry for a bridge ID |
| `lookup_runtime/1` | Returns `{:ok, %{listener_pids, state_pid}}` or `{:error, :not_running}` |
| `lookup_state_pid/1` | Returns `{:ok, pid}` or `{:error, :not_running}` |
| `start_listener/1` | Convenience — delegates to `Router.sync_config_runtime/2` |
| `stop_listener/1` | Convenience — delegates to `Router.sync_config_runtime/2` |

### Bootstrap

On startup, `load_initial_listeners/0` queries `ChannelConfig.list_enabled_by_kind(:retrieval, providers)` for all providers that have a configured `:adapter` in app config, and calls `Router.sync_config_runtime/2` for each.

`Zaq.NodeRouter` locates the channels node by calling `Process.whereis(Zaq.Channels.Supervisor)`.

---

## Channel Config

`Zaq.Channels.ChannelConfig` (schema: `channel_configs`) stores connector configurations. One record per provider (unique constraint on `provider`).

### Fields

| Field | Type | Notes |
|---|---|---|
| `name` | string | Human label |
| `provider` | string | One of: `mattermost`, `slack`, `teams`, `google_drive`, `sharepoint`, `email:smtp`, `telegram`, `discord` |
| `kind` | string | `"ingestion"` or `"retrieval"` |
| `url` | string | Base URL for the platform API |
| `token` | EncryptedString | Bot token — stored encrypted via `Zaq.Types.EncryptedString` |
| `enabled` | boolean | Default `true` |
| `settings` | map | Provider-specific settings |

### jido_chat settings

jido_chat adapter fields live in `settings["jido_chat"]`:

| Key | Helper | Description |
|---|---|---|
| `"bot_name"` | `jido_chat_bot_name/1` | Bot display name |
| `"bot_user_id"` | `jido_chat_bot_user_id/1` | Bot user ID on the platform |
| `"message_patterns"` | via `jido_chat_setting/3` | List of regex pattern strings for channel message matching |
| `"ingress"` | via `jido_chat_setting/3` | Ingress mode overrides map |

### Query functions

| Function | Description |
|---|---|
| `get_by_provider/1` | Returns enabled config for a provider |
| `get_any_by_provider/1` | Returns config regardless of `enabled` state |
| `upsert_by_provider/2` | Insert or update config for a provider |
| `list_enabled_by_kind/2` | Enabled configs for a kind, filtered by provider list |
| `get_by_channel_id/2` | Joins through `retrieval_channels` to find config for a platform channel ID |

---

## Retrieval Channel

`Zaq.Channels.RetrievalChannel` (schema: `retrieval_channels`) represents a specific platform channel that ZAQ monitors. Each record links a platform channel ID to a `ChannelConfig`.

### Fields

`channel_config_id`, `channel_id`, `channel_name`, `team_id`, `team_name`, `active` (default `true`).

Unique constraint: `[channel_config_id, channel_id]`.

### Query functions

| Function | Description |
|---|---|
| `list_active_by_config/1` | All active channels for a config ID |
| `list_by_config/1` | All channels (active and inactive) for a config ID, ordered by name |
| `get_by_config_and_channel/2` | Single channel by config ID and platform channel ID |
| `active_channel_ids/1` | All active channel IDs for a provider string |

When `list_active_by_config/1` returns non-empty results, the listener is started with those specific channel IDs. When empty, the listener receives `:all` — it subscribes to all channels.

---

## Mattermost Admin

`Zaq.Channels.MattermostAdmin` provides admin operations for the Mattermost channel configuration UI. Backed by `Jido.Chat.Mattermost.Transport.ReqClient`. Not intended for bot ingress/egress.

| Function | Description |
|---|---|
| `send_message/2` | Sends a message to a channel (loads config from DB) |
| `fetch_bot_user_id/2` | Fetches bot user ID via `/api/v4/users/me` |
| `list_teams/1` | Lists teams the bot belongs to |
| `list_public_channels/2` | Lists public channels for a team |
| `clear_channel/1` | Deletes all posts in a channel (destructive) |

---

## What's Done

- Router with full outbound API: `deliver`, `send_typing`, `add_reaction`, `remove_reaction`, `subscribe_thread_reply`, `unsubscribe_thread_reply`, `sync_config_runtime`, `test_connection`
- `JidoChatBridge` with ingress via `from_listener` / `sink_mfa`, outbound via `send_reply`, thread watch management, configurable ingress modes, and Oban-based on_reply dispatch
- `JidoChatBridge.State` GenServer with serialized message processing, config refresh preserving runtime state, and full reaction/typing delegation
- `EmailBridge` for SMTP delivery
- `WebBridge` for LiveView sessions via PubSub (with status callback support)
- `Supervisor` with ETS-backed runtime tracking and bootstrap on startup
- `ChannelConfig` with encrypted token storage, jido_chat settings helpers, and full query API
- `RetrievalChannel` with active/all channel queries
- `MattermostAdmin` for UI-facing admin operations
- Canonical `Incoming` / `Outgoing` structs as the adapter boundary contract
- All cross-node calls routed through `Zaq.NodeRouter`
