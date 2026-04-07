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
- For channel bridges, keep ingress callback names generic (`from_listener/3`) and transport-agnostic.
- Channel adapters own transport runtime specs and listener construction; bridges must not build adapter-specific listener specs.

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

## Abstraction Rules

### When to extract a module

- Extract when a group of functions shares a single, nameable responsibility.
- Do NOT extract just to reduce file length — a long file with one clear responsibility is better than two short files with blurry ones.
- Extract adapters and behaviours at **external boundaries** (LLM, HTTP, file system, DB drivers) so the core domain never imports third-party libs directly.

### When to inline

- Keep it inline if the helper is used once and the name adds no clarity over the code itself.
- Private helpers that exist only to break up a large function are fine to stay in the same module.

### Layering — where does new code go?

| What you're writing | Where it lives |
|---|---|
| Business rule / domain logic | `lib/zaq/<context>/` context module |
| Persistence query | Same context module, private query builder |
| External API call | `lib/zaq/<context>/adapters/<provider>.ex` |
| Background job | `lib/zaq/<context>/<name>_worker.ex` (Oban) |
| Complex multi-step operation (FS + DB, rollback) | `lib/zaq/<context>/<name>_service.ex` |
| UI logic / event handling | LiveView module |
| Cross-cutting behaviour | Behaviour module + adapter per provider |
| Pure shared utilities (≥3 callers) | `lib/zaq/shared/` |

### Behaviours at external boundaries

- Define a behaviour whenever there are (or will be) multiple implementations, or when the implementation must be swappable in tests.
- Every external channel type gets its own behaviour: see `Zaq.Engine.IngestionChannel`, `RetrievalChannel`, `NotificationChannel`, `Zaq.DocumentProcessorBehaviour`.
- Do NOT define a behaviour for a single implementation with no test-seam need.

### Canonical boundary structs

- When data crosses a service boundary, define a canonical struct with `@enforce_keys`.
- Adapter-specific envelopes must never leak inward — always map to the canonical struct first.
- Example: `Zaq.Engine.Messages.Incoming` / `Outgoing` are the only structs that flow between adapters and the rest of ZAQ.

### State transitions belong in their own module

- When state transitions have associated side effects (PubSub broadcast, audit log), extract them into a dedicated module so the side effect can never be missed.
- Example: Zaq.Ingestion.JobLifecycle owns all `IngestJob` transitions + broadcast — no caller transitions state directly.

### Single-operation services

- When an operation is complex (multi-step, involves FS + DB, or has a rollback strategy), extract it into a focused `*Service` module.
- Do not spread the operation across a context module and a LiveView.
- Examples: Zaq.Ingestion.DeleteService, Zaq.Ingestion.RenameService.

### Oban workers carry only IDs

- Never put large payloads in Oban job args — store the payload in the DB and pass only the primary key.
- Reason: payload is preserved across restarts and is readable for audit without deserializing job args.
- Example: `DispatchWorker` carries only `log_id`; `TokenUsageAggregator` carries `message_id`.

### Injectable modules for testability

- When a module calls a cross-node service or external integration, make the dependency injectable via `Application.get_env(:zaq, :module_key, DefaultModule)`.
- This allows test overrides without mocking internals.
- Example: `JidoChatBridge` injects `:chat_bridge_pipeline_module`, `:chat_bridge_router_module`, etc.

### Stateless routers

- Routers must not own process state — resolution happens at runtime from app config or DB.
- Routers resolve the correct bridge/adapter and delegate; they do not implement delivery logic.
- Example: `Zaq.Channels.Router` resolves provider → bridge from app config and calls `bridge.send_reply/2`.

### GenServer for serialized mutations

- Use a GenServer when you need to serialize mutations to a shared data structure from concurrent sources.
- Example: `Zaq.Channels.JidoChatBridge.State` owns `%Jido.Chat{}` and serializes all message processing through `handle_call` to prevent race conditions.

### Async side effects via `Task.start`

- Non-critical async side effects (title generation, welcome emails) should be dispatched via `Task.start/1`, not awaited.
- This ensures the main write path is never blocked by a secondary operation.
- Example: `TitleGenerator.generate/1` is called inside `Task.start/1` after message persistence.

### Shared helpers stay private until needed

- A helper shared by two contexts is NOT automatically worth its own module.
- Extract a shared module only when ≥3 callers exist or the logic is complex enough to warrant isolated testing.
- Small internal utilities (`SmtpHelpers`, `SourcePath`) stay as internal modules — do not expose them in the public context API.

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
