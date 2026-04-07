# IMAP Email Receiver Implementation Plan

## Overview

This plan implements inbound email reception via IMAP for the Channels service, complementing the existing SMTP outbound capability. The implementation follows the established channel architecture patterns and uses the `mailroom` library for IMAP operations.

## Requirements Summary

1. **Dedicated email account**: Provide IMAP credentials for ZAQ to receive emails
2. **Mailbox selection**: Explicitly select mailboxes/folders to listen to (channel cannot be enabled without selection)
3. **Per-mailbox listeners**: Each selected mailbox has a dedicated IDLE listener process supervised by `Channels.Supervisor`
4. **Pipeline relay**: Incoming emails are automatically relayed to the Agent pipeline
5. **Separate configs**: Incoming uses `email:imap` config, outgoing keeps `email:smtp`
6. **Dependency validation**: IMAP config cannot be enabled without SMTP config being set (needed for replies)

## Architecture Decisions

### Provider Separation
- `email:smtp` - Existing provider for outbound email delivery (remains unchanged)
- `email:imap` - New provider for inbound email reception

### Bridge Pattern
Following the existing `EmailBridge` pattern, we extend it to support **both** SMTP (outbound) and IMAP (inbound) operations:
- `EmailBridge` becomes a unified bridge handling email as a transport
- Implements `start_runtime/1` and `stop_runtime/1` for IMAP listener lifecycle
- Maintains `send_reply/2` for SMTP outbound (existing functionality)

### Runtime Model
Unlike `JidoChatBridge` which uses a stateful GenServer per bridge, `EmailBridge` for IMAP:
- Spawns **one listener process per selected mailbox** via `Supervisor.start_runtime/3`
- Each mailbox listener is an independent GenServer that:
  - Connects to IMAP server
  - Enters IDLE mode for real-time notifications
  - Handles reconnection on timeout
  - Fetches and processes new emails
  - Marks processed emails as read

## Module Responsibilities

| Module | Responsibility |
|--------|----------------|
| `Zaq.Channels.EmailBridge` | Bridge interface for email channel. Implements `start_runtime/1`, `stop_runtime/1`, `send_reply/2`, `to_internal/2`. Coordinates SMTP and IMAP operations. |
| `Zaq.Channels.EmailBridge.ImapListener` | GenServer that manages one IMAP IDLE connection per mailbox. Handles connect, IDLE, reconnection, fetch, and mark-as-read. Emits `Incoming` messages to pipeline. |
| `Zaq.Channels.EmailBridge.ImapConfig` | Settings schema and validation for IMAP configuration (server, port, ssl, username, password, selected_mailboxes). |
| `Zaq.Channels.ChannelConfig` | Extended to support `email:imap` provider validation (requires selected_mailboxes, requires smtp config). |
| `Zaq.Channels.Supervisor` | Starts/stops IMAP listener child processes via `start_runtime/3`. No changes needed - generic enough. |
| `Zaq.Channels.Router` | Extended to route `email:imap` provider to `EmailBridge`. No changes needed - already generic. |
| `Zaq.Engine.Messages.Incoming` | Used as-is for email messages (content, channel_id=mailbox, author_id=sender, thread_id=message_id for threading). |

## Data Model Changes

### ChannelConfig Settings Extension

```elixir
# For provider "email:imap"
settings["imap"] = %{
  "server" => "imap.gmail.com",
  "port" => 993,
  "ssl" => true,
  "username" => "zaq@example.com",
  "password" => <encrypted>,
  "selected_mailboxes" => ["INBOX", "Support"],  # Required, min 1
  "mark_as_read" => true,  # Default true
  "poll_interval" => 30000  # Fallback poll when IDLE not supported
}
```

### Validation Rules (ChannelConfig.changeset)

1. `email:imap` requires `settings["imap"]["selected_mailboxes"]` with at least one entry
2. `email:imap` cannot be enabled unless `email:smtp` config exists and is enabled
3. Sensitive fields (password) encrypted via `EncryptedString`

## Process Supervision Tree

```
Zaq.Channels.Supervisor (DynamicSupervisor)
├── email:imap_1_INBOX (ImapListener GenServer)
├── email:imap_1_Support (ImapListener GenServer)
└── ... (one per selected mailbox)
```

Each listener:
- `bridge_id`: `"email:imap_#{config.id}_#{mailbox_name}"`
- `state_pid`: nil (stateless - IMAP client is internal to listener)
- `listener_pids`: [self]

## Message Flow

```
IMAP Server
    │
    ▼ IDLE notification
ImapListener (per mailbox)
    │
    ▼ Mailroom.IMAP.fetch()
    │
    ▼ Parse email (Mailroom.Parsing)
    │
    ▼ Build %Incoming{
    │     content: email.body_text,
    │     channel_id: mailbox_name,
    │     author_id: email.from.address,
    │     author_name: email.from.name,
    │     thread_id: email.in_reply_to || email.message_id,
    │     message_id: email.message_id,
    │     provider: :email,
    │     metadata: %{subject: email.subject, ...}
    │   }
    │
    ▼ Zaq.Agent.Pipeline.run()
    │
    ▼ Zaq.Channels.Router.deliver() [if reply]
    │
    ▼ Mark as read (if configured)
```

## Implementation Steps

### Phase 1: Foundation
1. Add `mailroom` dependency to `mix.exs`
2. Create `Zaq.Channels.EmailBridge.ImapConfig` module
3. Extend `ChannelConfig` validation for `email:imap` provider

### Phase 2: IMAP Listener
4. Create `Zaq.Channels.EmailBridge.ImapListener` GenServer
   - `start_link/1` with config and mailbox_name
   - `init/1` connects to IMAP server
   - `handle_info/2` for IDLE callbacks
   - `handle_info/2` for reconnection logic
   - `terminate/2` for cleanup

### Phase 3: Bridge Integration
5. Extend `EmailBridge`:
   - Add `start_runtime/1` - spawns listeners for each selected mailbox
   - Add `stop_runtime/1` - stops all listeners for config
   - Implement `to_internal/2` - parses Mailroom email to `%Incoming{}`

### Phase 4: Validation & Testing
6. Add validation: IMAP requires SMTP
7. Add tests for IMAP listener
8. Add tests for bridge integration
9. Add integration tests (mock IMAP server)

### Phase 5: Configuration UI (Future)
10. LiveView for IMAP configuration
11. Mailbox listing UI (test connection + list folders)

## Configuration Example

```elixir
# Runtime config
config :zaq, :channels, %{
  email: %{
    bridge: Zaq.Channels.EmailBridge,
    # No adapter needed - mailroom is direct dependency
  }
}
```

## Error Handling

| Scenario | Behavior |
|----------|----------|
| IMAP connection fails | Listener crashes, Supervisor restarts with backoff |
| IDLE timeout | Automatic reconnection with `idle/1` |
| Authentication failure | Log error, stop listener, mark config as error state |
| SMTP not configured | Validation error on enable attempt |
| No mailboxes selected | Validation error on save |
| Mailbox no longer exists | Log warning, skip that mailbox, continue others |

## Security Considerations

1. IMAP password encrypted at rest (via `EncryptedString`)
2. SSL/TLS enforced by default for IMAP connections
3. Credentials never logged
4. IMAP config only accessible by admin users

## Testing Strategy

1. **Unit tests**: `ImapConfig` validation, `to_internal/2` parsing
2. **GenServer tests**: `ImapListener` with mocked Mailroom.IMAP
3. **Integration tests**: Full flow with fake IMAP server (mailroom test helpers)
4. **Bridge tests**: `start_runtime`/`stop_runtime` lifecycle

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:mailroom, "~> 0.7"},
    # ... existing deps
  ]
end
```

## Open Questions

1. Should we support OAuth2 for Gmail/Outlook IMAP?
2. How to handle email threading (In-Reply-To vs References headers)?
3. Should we support multiple IMAP accounts (multi-tenant)?
4. Attachment handling - download or pass URL?
5. HTML vs plain text preference for `Incoming.content`?

## Success Criteria

- [ ] Can configure `email:imap` with selected mailboxes
- [ ] IMAP listener processes start when channel enabled
- [ ] Incoming emails trigger Agent pipeline
- [ ] Replies sent via existing SMTP config
- [ ] Processed emails marked as read
- [ ] Listeners restart on application boot if config enabled
- [ ] Listeners stop when channel disabled
- [ ] Cannot enable IMAP without SMTP configured

---

**Created**: 2026-04-07
**Author**: OpenCode Agent
**Status**: Draft
**Related Issue**: [communication channel] email - IMAP inbound support
