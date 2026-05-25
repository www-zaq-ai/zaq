# Engine Service

## Overview

The Engine service is the operational backbone of ZAQ. It owns four distinct
responsibilities:

1. **Conversations** — persisting and querying the full conversation/message/rating lifecycle.
2. **Notifications** — routing outbound notifications (email, etc.) through a centralized
   dispatch pipeline with audit logging.
3. **Channel Adapters** — supervising ingestion channel adapters (document sources) and
   retrieval channel adapters (messaging platforms).

The Engine runs under the `:engine` role. The top-level `Zaq.Engine.Supervisor` starts
`Zaq.Engine.Telemetry.Supervisor`, `Zaq.Engine.IngestionSupervisor`, and
`Zaq.Engine.RetrievalSupervisor` under a `:one_for_one` strategy.

Telemetry is a separate concern — see `docs/services/telemetry.md`.

**Important**: BO LiveViews must never call `Zaq.Engine.Conversations` directly. For
invoke-style cross-service calls, use `Zaq.Engine.Events.build_and_dispatch_invoke_event/3`
instead of constructing `%Zaq.Event{}` inline.

---

## Startup

The `:engine` role must be included in `:roles` config or the `ROLES` env var:

```elixir
# config/dev.exs
config :zaq, roles: [:bo, :agent, :ingestion, :channels, :engine]
```

```bash
ROLES=engine iex --sname engine@localhost --cookie zaq_dev -S mix
```

---

## Data Flow

### Conversations

```
Channel adapter or BO chat
  → Zaq.Engine.Conversations.persist_from_incoming/2
      → get_or_create_conversation_for_channel/3
      → add_message/2   (role: "user")
      → add_message/2   (role: "assistant")
          → Telemetry.record("qa.message.count" / "qa.answer.count")
          → TokenUsageAggregator Oban job (enqueued if model present)
          → TitleGenerator.generate/1 (async Task on first user message)
              → broadcasts {:title_updated, id, title} on "conversation:<id>"
```

### Notifications

```
Caller builds %Notification{} via Notification.build/1
  → Notifications.notify/1
      → filters recipient_channels against enabled ChannelConfig rows
      → NotificationLog.create_log/1         ← creates audit record
      → DispatchWorker Oban job enqueued     ← queue: :notifications, max_attempts: 1
          → reads payload from NotificationLog
          → builds %Outgoing{} for each channel
          → Channels.Api handle_event(:deliver_outgoing) via NodeRouter.dispatch/1
              → on success: NotificationLog.transition_status("sent")
              → on failure: tries next channel; "failed" if all exhausted
```

### Channel adapter lifecycle

```
IngestionSupervisor.init/1
  → ChannelAdapterLoader.children_for(:ingestion, @adapters, start_fun: :start_link)
      → ChannelConfig.list_enabled_by_kind(:ingestion, providers)
      → starts one child per enabled config

RetrievalSupervisor.init/1
  → ChannelAdapterLoader.children_for(:retrieval, @adapters, start_fun: :connect)
      → starts one child per enabled config

Adapter inbound path:
  External platform → adapter.handle_event/1
    → adapter maps to %Messages.Incoming{}
    → adapter.forward_to_engine/1
    → Agent Pipeline
    → %Messages.Outgoing{} via Outgoing.from_pipeline_result/2
    → Channels.Api handle_event(:deliver_outgoing) via NodeRouter.dispatch/1
```

---

## Modules

### Supervisor (`Zaq.Engine.Supervisor`)
- Top-level supervisor for the `:engine` role.
- `:one_for_one` children: `Telemetry.Supervisor` (see `docs/services/telemetry.md`), `IngestionSupervisor`, `RetrievalSupervisor`.

### Conversations Context (`Zaq.Engine.Conversations`)
- Public API for the full conversation/message/rating/share lifecycle.
- Access from BO via `Zaq.Engine.Events.build_and_dispatch_invoke_event/3`.
- Dispatches `Zaq.Hooks` `:feedback_provided` event after a rating is saved.

**Key functions:**
- `create_conversation/1` — insert a new conversation.
- `get_conversation/1`, `get_conversation!/1` — fetch by UUID.
- `get_or_create_conversation_for_channel/3` — idempotent; returns the most recent
  active conversation for `{channel_user_id, channel_type, channel_config_id}` or creates one.
- `list_conversations/1` — filtered list; opts: `user_id`, `channel_user_id`, `channel_type`,
  `status`, `limit`.
- `update_conversation/2`, `archive_conversation/1`, `delete_conversation/1` — lifecycle.
- `persist_from_incoming/2` — convenience: upserts conversation + stores both user and
  assistant messages from a pipeline result in one call.
- `add_message/2` — inserts a message, records telemetry, enqueues token aggregation,
  triggers async title generation on first user message.
- `list_messages/1` — all messages for a conversation in insertion order, preloads ratings.
- `rate_message/2`, `get_rating/2`, `update_rating/2`, `delete_rating/1` — per-message
  rating CRUD.
- `rate_message_by_id/2` — upserts a rating by message UUID; dispatches `:feedback_provided`
  hook after success.
- `share_conversation/2`, `list_shares/1`, `revoke_share/1` — share link management.
- `get_conversation_by_token/1` — resolves a conversation from a share token.

### People Command Gateway (`Zaq.Engine.PeopleGateway`)
- BO People operations are routed through `Zaq.Engine.Events.build_and_dispatch_invoke_event/3`
  to Engine using `action: :people_command`.
- `Zaq.Engine.Api` validates `%{op: atom(), params: map()}` and delegates to
  `Zaq.Engine.PeopleGateway.dispatch/2`.
- Gateway maps operations (`:filter`, `:create`, `:update`, `:delete`, `:bulk_delete`,
  team/channel operations, etc.) to `Zaq.Accounts.People` domain calls.

### Conversation Title Generator (`Zaq.Engine.Conversations.TitleGenerator`)
- Generates a 6-word-max title from the first user message via LLM.
- Uses `Zaq.Agent.LLM.chat_config/1` and `Zaq.Agent.LLMRunner`.
- Called asynchronously (`Task.start/1`) — never blocks the message-storage path.
- Broadcasts `{:title_updated, id, title}` on `"conversation:<id>"` PubSub topic on success.
- `generate/2` — returns `{:ok, title} | {:error, reason}`.

### Token Usage Aggregator (`Zaq.Engine.Conversations.TokenUsageAggregator`)
- Oban worker; queue: `:conversations`, max 3 attempts.
- Triggered after each assistant message that has a non-nil `model`.
- Aggregates daily `prompt_tokens` + `completion_tokens` per model into
  `conversation.metadata["token_usage"][date][model]`.

### Messages — Incoming (`Zaq.Engine.Messages.Incoming`)
- Canonical struct for all inbound messages crossing the adapter boundary.
- Enforce keys: `:content`, `:channel_id`, `:provider`.
- Optional: `:author_id`, `:author_name`, `:thread_id`, `:message_id`, `:person_id`, `:metadata`.
- All channel adapters must map their transport payload to this struct before passing to any
  ZAQ component.
- When crossing nodes, this payload is carried in `%Zaq.Event.request`.

### Messages — Outgoing (`Zaq.Engine.Messages.Outgoing`)
- Canonical struct for all outbound messages.
- Enforce keys: `:body`, `:channel_id`, `:provider`.
- `from_pipeline_result/2` — builds an `%Outgoing{}` from an `%Incoming{}` and a pipeline
  result map; copies routing fields and stores result map in `metadata`.
- When crossing nodes, this payload is typically returned in `%Zaq.Event.response`.

### Notifications Context (`Zaq.Engine.Notifications`)
- Single exit point for all outbound communication from ZAQ.
- `notify/1` — accepts only a validated `%Notification{}` struct.
  - Filters `recipient_channels` against enabled `ChannelConfig` rows.
  - Creates a `NotificationLog` record, then enqueues `DispatchWorker`.
  - Returns `{:ok, :dispatched}` or `{:ok, :skipped}`.
- `bridge_available?/1` — returns true if a bridge is configured for the given platform.

### Notification Struct (`Zaq.Engine.Notifications.Notification`)
- Build via `Notification.build/1` — validates subject, body, channel format.
- Fields: `recipient_channels`, `sender`, `subject`, `body`, `html_body`,
  `recipient_name`, `recipient_ref`, `metadata`.
- `recipient_ref` type: `{:user, integer()} | {:person, integer()} | nil`.

### Notification Log (`Zaq.Engine.Notifications.NotificationLog`)
- Ecto schema (`notification_logs`); stores payload (subject/body) and delivery audit trail.
- Status lifecycle: `pending → sent | skipped | failed`.
- `create_log/1` — inserts with status `"pending"`.
- `append_attempt/3` — atomic Postgres JSONB `||` append to `channels_tried`; safe for
  concurrent Oban retries.
- `transition_status/2` — enforces valid transitions; uses `update_all` with current-status
  guard for stale-record safety.

### Dispatch Worker (`Zaq.Engine.Notifications.DispatchWorker`)
- Oban worker; queue: `:notifications`, max 1 attempt.
- Reads payload from `NotificationLog` at execution time (args carry only `log_id`).
- Tries channels sequentially; stops on first success.
- Delivers via channels role dispatch (`Zaq.Channels.Api` through `Zaq.NodeRouter.dispatch/1`), with bridge delivery delegated by channels modules.
- Router module is injectable via `Application.get_env(:zaq, :dispatch_worker_router_module)`.

### Email Notification (`Zaq.Engine.Notifications.EmailNotification`)
- Delivers via SMTP using Swoosh/Mailer.
- SMTP settings read from `ChannelConfig` for provider `"email:smtp"`.
- `send_notification/3` — builds Swoosh email and calls `Zaq.Mailer.deliver/2`.
- Supports SSL, STARTTLS, `verify_peer`/`verify_none`, custom CA cert path.
- Password field is decrypted via `Zaq.Types.EncryptedString.decrypt/1`.

### Welcome Email (`Zaq.Engine.Notifications.WelcomeEmail`)
- `deliver/1` — builds and dispatches a welcome email to a newly created user via
  `Notifications.notify/1`. Skips if the user has no email address.

### Password Reset Email (`Zaq.Engine.Notifications.PasswordResetEmail`)
- `deliver/2` — builds and dispatches a password reset email with a one-time token URL.
  Skips if the user has no email address.

### Ingestion Channel Behaviour (`Zaq.Engine.IngestionChannel`)
- Behaviour contract for document-source adapters.
- Required callbacks: `connect/1`, `disconnect/1`, `list_documents/1`, `fetch_document/2`.
- Optional callbacks: `schedule_sync/1` (polling), `handle_event/2` (event-driven).

### Retrieval Channel Behaviour (`Zaq.Engine.RetrievalChannel`)
- Behaviour contract for messaging platform adapters.
- Required callbacks: `connect/1`, `disconnect/1`, `send_message/3`, `send_question/2`,
  `handle_event/1`, `forward_to_engine/1`.

### Notification Channel Behaviour (`Zaq.Engine.NotificationChannel`)
- Behaviour contract for notification delivery adapters.
- Required callbacks: `available?/1`, `send_notification/2`.

### Ingestion Supervisor (`Zaq.Engine.IngestionSupervisor`)
- Starts one child process per enabled ingestion `ChannelConfig`.
- Registered adapters: `"google_drive"` → `Zaq.Channels.Ingestion.GoogleDrive`,
  `"sharepoint"` → `Zaq.Channels.Ingestion.SharePoint`.
- Adapters started via `start_link/1`; `:permanent` restart strategy.
- Starts empty without crashing when no configs are found.

### Retrieval Supervisor (`Zaq.Engine.RetrievalSupervisor`)
- Starts one child process per enabled retrieval `ChannelConfig`.
- Registered adapters: `"slack"` → `Zaq.Channels.Retrieval.Slack`.
- Adapters started via `connect/1`; `:permanent` restart strategy.
- `adapter_for/1` — returns adapter module for a provider string or `nil`.

### Channel Adapter Loader (`Zaq.Engine.ChannelAdapterLoader`)
- Shared helper used by both supervisors.
- `children_for/3` — loads enabled configs, maps providers to adapter modules, builds
  Supervisor child specs.
- `load_configs/4` — queries `ChannelConfig.list_enabled_by_kind/2`; logs and returns `[]`
  when no configs found.
- `build_child_spec/5` — returns `[]` (with warning) for unknown providers.

For telemetry modules (`Zaq.Engine.Telemetry`, `Buffer`, `Collector`, workers), see `docs/services/telemetry.md`.

### Schemas

**`Zaq.Engine.Conversations.Conversation`** (`conversations`)
- Fields: `title`, `channel_user_id`, `channel_type`, `channel_config_id`, `status`,
  `metadata`, `user_id`.
- Valid channel types: `mattermost`, `slack`, `bo`, `api`.
- Valid statuses: `active`, `archived`.
- Primary key: UUID (`:binary_id`).

**`Zaq.Engine.Conversations.Message`** (`messages`)
- Fields: `role`, `content`, `model`, `prompt_tokens`, `completion_tokens`,
  `total_tokens`, `confidence_score`, `sources`, `latency_ms`, `metadata`.
- Valid roles: `user`, `assistant`.
- No `updated_at` timestamp.

**`Zaq.Engine.Conversations.MessageRating`** (`message_ratings`)
- Fields: `rating` (1–5), `comment`, `channel_user_id`, `user_id`, `message_id`.
- Unique constraint on `(message_id, user_id)`.

**`Zaq.Engine.Conversations.ConversationShare`** (`conversation_shares`)
- Fields: `share_token` (auto-generated, URL-safe base64), `permission` (only `"read"`),
  `expires_at`, `shared_with_user_id`.
- Unique constraints on `share_token` and `(conversation_id, shared_with_user_id)`.

For telemetry schemas (`Point`, `Rollup`) and dashboard contracts, see `docs/services/telemetry.md`.

---

## Files

```
lib/zaq/engine/
├── conversations/
│   ├── conversation.ex               # Ecto schema: conversations table
│   ├── conversation_share.ex         # Ecto schema: conversation_shares table
│   ├── message.ex                    # Ecto schema: messages table
│   ├── message_rating.ex             # Ecto schema: message_ratings table
│   ├── title_generator.ex            # Async LLM-based conversation title generation
│   └── token_usage_aggregator.ex     # Oban worker: daily token usage rollup per model
├── messages/
│   ├── incoming.ex                   # Canonical inbound message struct
│   └── outgoing.ex                   # Canonical outbound message struct
├── notifications/
│   ├── dispatch_worker.ex            # Oban worker: delivers notification via channels
│   ├── email_notification.ex         # SMTP email delivery via Swoosh
│   ├── notification.ex               # Notification struct + build/1 validation
│   ├── notification_log.ex           # Ecto schema + audit trail for notifications
│   ├── password_reset_email.ex       # Password reset email builder/dispatcher
│   └── welcome_email.ex              # Welcome email builder/dispatcher
├── telemetry/                        # See docs/services/telemetry.md
├── channel_adapter_loader.ex         # Shared child-spec builder for supervisors
├── conversations.ex                  # Public API: conversations/messages/ratings/shares
├── ingestion_channel.ex              # Behaviour contract for ingestion adapters
├── ingestion_supervisor.ex           # Supervises ingestion channel adapter processes
├── notification_channel.ex           # Behaviour contract for notification adapters
├── notifications.ex                  # Public API: notify/1 dispatch pipeline
├── retrieval_channel.ex              # Behaviour contract for retrieval adapters
├── retrieval_supervisor.ex           # Supervises retrieval channel adapter processes
├── supervisor.ex                     # Top-level supervisor for the :engine role
└── telemetry.ex                      # See docs/services/telemetry.md
```

---

## Configuration

SMTP configuration is read from `ChannelConfig` for provider `"email:smtp"`.

For all `telemetry.*` system config keys, see `docs/services/telemetry.md`.

Oban queues used by the Engine:

- `:notifications` — notification dispatch (concurrency from `Oban` config)
- `:conversations` — token usage aggregation
- `:telemetry` and `:telemetry_remote` — see `docs/services/telemetry.md`

---

## Key Design Decisions

- **NodeRouter for cross-node calls** — BO LiveViews never call `Conversations` directly;
  all calls are routed via `NodeRouter` (prefer `dispatch/1`).
- **Notification payload stored in DB** — `DispatchWorker` Oban args carry only `log_id`;
  subject/body is read from `NotificationLog` at execution time, preventing payload loss
  across Oban restarts.
- **Notification dispatch is fire-and-forget (max_attempts: 1)** — non-retrying by design;
  the caller receives `{:ok, :dispatched}` immediately.
- **Atomic JSONB append** — `NotificationLog.append_attempt/3` uses a raw Postgres `||`
  fragment to avoid lost writes from concurrent Oban retries.
- **Conversation title is generated async** — `Task.start/1` so title generation never
  blocks message persistence; title update is broadcast on PubSub.
- **Token aggregation via Oban** — `TokenUsageAggregator` enqueues a job per assistant
  message; aggregation is idempotent (overwrites the day's model bucket on each run).
- **Channel adapters registered at compile time** — `IngestionSupervisor` and
  `RetrievalSupervisor` hold a `@adapters` module attribute mapping provider strings
  to adapter modules; adding a new adapter requires only a map entry plus a DB config row.

---

## What's Left

### Should Do
- [ ] Dynamic adapter hot-loading — currently adapters are resolved only at supervisor
  startup; adding/removing a ChannelConfig requires an Engine node restart.
- [ ] Conversation pruning — no lifecycle management for old conversations; storage grows
  unbounded.
- [ ] Notification retry strategy — `DispatchWorker` is `max_attempts: 1`; transient SMTP
  failures are not retried.

### Nice to Have
- [ ] Notification channel adapter for Slack/Mattermost direct messages
