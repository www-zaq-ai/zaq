# Conventions

## Naming

| What | Convention | Example |
|---|---|---|
| Contexts | `lib/zaq/<context>/` | `Zaq.Accounts`, `Zaq.Ingestion` |
| LiveViews | `lib/zaq_web/live/bo/<section>/` | `ZaqWeb.Live.BO.Communication.ConversationsLive` |
| LiveView modules | `ZaqWeb.Live.BO.<Section>.<n>Live` | `ZaqWeb.Live.BO.AI.IngestionLive` |
| Context functions | `create_x/1`, `update_x/2`, `delete_x/1` | `create_user/1`, `update_role/2` |
| Schemas | `Zaq.<Context>.<Entity>` | `Zaq.Accounts.User` |
| Channel adapters | `Zaq.Channels.<Kind>.<Provider>` | `Zaq.Channels.Retrieval.Mattermost` |
| Background jobs | Oban workers under `lib/zaq/ingestion/` | `Zaq.Ingestion.IngestWorker` |
| Predicate functions | end in `?`, never start with `is_` | `admin?/1`, not `is_admin/1` |

---

## Module & API Design

- Public APIs use `{:ok, result}` / `{:error, reason}` for fallible operations.
- Use `raise` and bang functions only for exceptional cases or explicit bang APIs.
- Add `@spec` for public functions in contexts, behaviours, and adapters.
- Document non-obvious invariants with `@doc`.
- Keep functions small and composable; move branching-heavy logic into focused private functions.
- Never nest multiple modules in the same file — causes cyclic dependencies and compilation errors.

---

## Context Boundaries

- Domain and business rules live in `lib/zaq/` contexts.
- LiveViews, controllers, plugs, and workers orchestrate and delegate — they do not own business logic.
- BO modules in `lib/zaq_web/` must not access persistence or integrations directly.
- Cross-context calls use public context functions, not internal helpers.
- Cross-service BO calls always go through `NodeRouter.call/4`.

---

## Data Access

- Keep Ecto queries and persistence logic in context/domain modules — never in LiveViews or templates.
- Keep HTTP/external calls in adapter/integration modules; depend on behaviours at domain boundaries.
- Preload associations when needed by rendering layers to prevent N+1 queries.
- Never use map access syntax (`changeset[:field]`) on structs — access fields directly via `my_struct.field`.
- Use `Ecto.Changeset.get_field/2` to access changeset fields.
- Fields set programmatically (e.g. `user_id`) must not be listed in `cast` calls — set them explicitly.

---

## Secrets & Sensitive Fields

- All sensitive values (API keys, tokens, passwords) must be encrypted before persistence.
- Use `Zaq.Types.EncryptedString.encrypt/1` in the write path.
- Never persist plaintext sensitive values — no fallback allowed.
- Current sensitive fields: `llm.api_key`, `embedding.api_key`, `image_to_text.api_key`, `email.password`, `channel_configs.token`.
- See `docs/services/system-config.md` for the full secret persistence checklist.

---

## Oban Workers

- Make Oban workers and external side-effect operations idempotent so retries are safe.
- Use unique job constraints to prevent duplicate work within time windows.
- Workers under queue `:ingestion` and `:ingestion_chunks` — see `docs/services/ingestion.md`.

---

## Temporary Code

- Any temporary shortcut must include a `TODO` with a linked issue and clear removal condition.
- Remove dead code and stale branches when replacing behavior — do not keep inactive paths "just in case".
- If a change intentionally diverges from established patterns, document the rationale in the PR description.

---

## Conversations Context

- Module: `lib/zaq/engine/conversations.ex`
- Schemas: `lib/zaq/engine/conversations/` (Conversation, Message, MessageRating, ConversationShare)
- All BO calls MUST go through `NodeRouter.call(:engine, Zaq.Engine.Conversations, ...)`
- `users` table uses integer PKs — FK fields in conversation schemas use `type: :integer`
- Anonymous channel users identified by `channel_user_id + channel_type` (no `user_id`)