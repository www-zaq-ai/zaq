# Channels Service

## Overview

The Channels service provides transport/runtime infrastructure for communication adapters.

- **Ingestion channels** ingest external documents.
- **Retrieval channels** receive user messages and deliver ZAQ responses.

For chat-style providers, ZAQ uses `Zaq.Channels.JidoChatBridge` with `jido_chat` adapters.

---

## Current Runtime Model

### Public outbound API

`Zaq.Channels.Router` is the public entrypoint used by internal modules.

- `deliver/1`
- `send_typing/2`
- `add_reaction/4`
- `remove_reaction/5`
- `subscribe_thread_reply/3`
- `unsubscribe_thread_reply/3`

The router resolves the bridge by provider and delegates provider-specific behavior to the bridge.

### Jido chat bridge runtime

`Zaq.Channels.JidoChatBridge` is the provider-facing implementation for jido_chat adapters.

- Ingress entrypoint: `from_listener/3` (adapter `sink_mfa` target)
- Outbound/event delegation: reply, typing, reactions
- Thread watch management: subscribe/unsubscribe reply threads

Runtime state is kept per `bridge_id` in `Zaq.Channels.JidoChatBridge.State`.

### Channels supervisor

`Zaq.Channels.Supervisor` manages process lifecycle only:

- starts/stops runtime units (state + optional listener)
- bootstraps enabled channel configs on startup
- provides runtime pid lookup by `bridge_id`

Business operations are handled in the bridge, not in the supervisor.

---

## Channel Config

`Zaq.Channels.ChannelConfig` stores connector configs in `channel_configs`.

- Core fields: `name`, `provider`, `kind`, `url`, `token`, `enabled`, `settings`
- jido_chat adapter fields are stored in `settings["jido_chat"]` (for example `bot_name`, `bot_user_id`)

---

## Notes

- Legacy Mattermost retrieval adapter modules were removed in favor of the jido_chat bridge flow.
- Retrieval/ingestion adapter behaviours remain defined under `lib/zaq/engine/`.
