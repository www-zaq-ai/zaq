# Notifications Service

## Overview

The Notifications service is ZAQ's single exit point for all outbound
communication — email, Mattermost, or any future channel. Callers build a
`%Notification{}` struct and call `Notifications.notify/1`. Everything else
(routing, filtering, logging, delivery) is handled internally.

Delivery is asynchronous: `notify/1` inserts an Oban job and returns
immediately. The Oban worker resolves adapters, tries each channel in sequence,
and records all outcomes in `notification_logs`.

---

## Data Flow

```
Caller
  → Notification.build/1              ← validates and constructs struct
  → Notifications.notify/1            ← filters to configured channels,
                                         creates NotificationLog (status: pending),
                                         inserts DispatchWorker Oban job
  → DispatchWorker.perform/1          ← reads log, tries each channel sequentially
      → NotificationAdapter.send_notification/3  ← platform-specific delivery
      → NotificationLog.append_attempt/3         ← records each attempt atomically
  → NotificationLog.transition_status/2          ← sets final status: sent/skipped/failed
```

---

## Key Modules

### `Zaq.Engine.Notifications` — context / entry point

The public API. All callers go through this module.

```elixir
@spec notify(Notification.t()) :: {:ok, :dispatched} | {:ok, :skipped}
@spec adapter_for(String.t()) :: module() | nil
```

- `notify/1` — only accepts a `%Notification{}` struct (use `Notification.build/1` first)
  - Returns `{:ok, :skipped}` when `recipient_channels` is empty or no channels
    are configured/enabled
  - Returns `{:ok, :dispatched}` when an Oban job is successfully enqueued
- `adapter_for/1` — returns the adapter module for a given platform string, or `nil`

Channel eligibility: a channel is included only if its platform appears in
`channel_configs` with `kind: "retrieval"` and `enabled: true`, AND an adapter
is registered for it in the internal `@adapter_registry`.

Registered platforms:

| Platform | Adapter |
|---|---|
| `"email:smtp"` | `Zaq.Engine.Notifications.EmailNotification` |
| `"mattermost"` | `Zaq.Channels.Retrieval.Mattermost.Notification` |

### `Zaq.Engine.Notifications.Notification` — struct

```elixir
@spec build(map()) :: {:ok, t()} | {:error, String.t()}
```

Required fields: `subject`, `body`.
Optional: `recipient_channels`, `sender` (default `"system"`), `recipient_name`,
`recipient_ref`, `html_body`, `metadata`.

Each channel must be `%{platform: String.t(), identifier: String.t()}`.
Empty `recipient_channels` is valid.

`recipient_ref` type: `{:user, integer()} | {:person, integer()} | nil`

### `Zaq.Engine.Notifications.NotificationLog` — Ecto schema

Audit log for every `notify/1` call. The full payload (subject + body) lives
here; Oban job args carry only `log_id`.

Status lifecycle: `pending → sent | skipped | failed`

```elixir
@spec create_log(map()) :: {:ok, %NotificationLog{}} | {:error, Ecto.Changeset.t()}
@spec append_attempt(integer(), String.t(), :ok | {:error, term()}) :: :ok
@spec transition_status(%NotificationLog{}, String.t()) ::
        {:ok, %NotificationLog{}} | {:error, :invalid_transition | :stale_record}
```

- `create_log/1` — inserts a new log record (status defaults to `"pending"`)
- `append_attempt/3` — atomically appends to `channels_tried` using a Postgres
  JSONB `||` fragment; safe for concurrent Oban retries
- `transition_status/2` — enforces state machine; uses `update_all` with a
  `WHERE status = current_status` guard to handle concurrent updates

### `Zaq.Engine.Notifications.DispatchWorker` — Oban worker

Queue: `:notifications`. `max_attempts: 1`.

Reads the `NotificationLog` by `log_id`, then tries each channel sequentially.
Stops on the first successful delivery. Adapter module names are stored as
strings in job args and resolved at runtime via `String.to_existing_atom/1` +
`Code.ensure_loaded?/1`.

### `Zaq.Engine.NotificationAdapter` — behaviour

```elixir
@callback send_notification(identifier :: String.t(), payload :: map(), metadata :: map()) ::
  :ok | {:error, term()}
```

- `identifier` — platform-specific recipient address (email, channel ID, etc.)
- `payload` — map with `"subject"`, `"body"`, optional `"html_body"`
- `metadata` — serialisable map; may include delivery hints (e.g. `"email_body"` override)

### `Zaq.Engine.Notifications.EmailNotification`

Implements `NotificationAdapter`. Delivers via Swoosh/Mailer with
`Swoosh.Adapters.SMTP`. SMTP settings are read at delivery time from
`channel_configs.settings` under provider `"email:smtp"`. Password is stored
encrypted via `Zaq.Types.EncryptedString`.

If no relay is configured, delivery options default to `[]` (Swoosh test
adapter).

### `Zaq.Engine.Notifications.WelcomeEmail`

```elixir
@spec deliver(Accounts.User.t()) :: {:ok, :dispatched} | {:ok, :skipped}
```

Sends a welcome email to a newly created user. Skipped silently if the user has
no email address. Reads `base_url` from `Application.get_env(:zaq, :base_url)`.

### `Zaq.Engine.Notifications.PasswordResetEmail`

```elixir
@spec deliver(Accounts.User.t(), String.t()) :: {:ok, :dispatched} | {:ok, :skipped}
```

Sends a password reset email with a reset URL. Skipped if the user has no email
address. Reset link is valid for 1 hour (enforced by the token, not this module).

---

## Configuration

SMTP settings are managed through the Back Office channel config UI (provider
`email:smtp`) and stored in `channel_configs.settings`. The following env vars
are documented in the module as fallback/reference:

| Variable | Default | Description |
|---|---|---|
| `SMTP_RELAY` | — | SMTP server hostname |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USERNAME` | — | SMTP auth username |
| `SMTP_PASSWORD` | — | SMTP auth password (encrypted at rest) |
| `SMTP_FROM_EMAIL` | `noreply@zaq.local` | Sender email address |
| `SMTP_FROM_NAME` | `ZAQ` | Sender display name |
| `SMTP_TLS` | `enabled` | TLS mode: `enabled` / `always` / `never` |

The `base_url` for email links is read from:

```elixir
Application.get_env(:zaq, :base_url, "http://localhost:4000")
```

---

## Files

```
lib/zaq/engine/
├── notification_adapter.ex              # Behaviour contract for adapters
├── notifications.ex                     # Context / entry point (notify/1)
└── notifications/
    ├── notification.ex                  # Struct + build/1 validation
    ├── notification_log.ex              # Ecto schema + status lifecycle
    ├── email_notification.ex            # SMTP adapter (implements NotificationAdapter)
    ├── dispatch_worker.ex               # Oban worker (queue: notifications)
    ├── welcome_email.ex                 # Welcome email helper
    └── password_reset_email.ex          # Password reset email helper
```

---

## What's Left

### Should Do
- [ ] `DispatchWorker` runs with `max_attempts: 1` — no automatic retry on delivery failure; failed channels are simply skipped
- [ ] Platform eligibility check queries `channel_configs` with `kind: "retrieval"` — a `kind: "notification"` concept does not exist yet

### Nice to Have
- [ ] Additional adapter registrations (Slack, Teams, webhook) beyond email and Mattermost
- [ ] Retry policy per channel (e.g. retry email on transient SMTP errors)
