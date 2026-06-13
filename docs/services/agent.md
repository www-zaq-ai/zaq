# Agent Service

## Overview

The Agent service is the AI layer of ZAQ. It handles query rewriting, response formulation,
confidence scoring, prompt security, and chunk title generation during ingestion.

Core pipeline modules remain stateless, but configured agents are now runtime-managed.
`Zaq.Agent.Supervisor` starts:
- `DynamicSupervisor` (named `:Zaq.Agent.AgentServerSupervisor`)
- `Zaq.Agent.ServerManager`

`ServerManager` maintains one long-lived `Jido.AgentServer` per configured agent id.
When `Executor` passes an explicit scope, that scope is encoded in `server_id`
(`<agent_name>:<scope>`) and `ServerManager` manages that runtime too.

Provider normalization and model-spec assembly are centralized in
`Zaq.Agent.ProviderSpec` + `Zaq.Agent.Factory` — no other module should read
or construct provider details directly.

**Important**: Agent modules must never be called directly from BO LiveViews.
All calls from BO go through `Zaq.NodeRouter` so they work correctly in both
single-node and multi-node deployments. For invoke-style calls, use
`Zaq.Agent.Events.build_and_dispatch_invoke_event/3` (or
`Zaq.Agent.Events.build_invoke_event/3` when dispatch is deferred) rather than
constructing `%Zaq.Event{}` inline.

---

## Entry Point Decision Tree

Before writing any new agent-service code, verify which entry point already covers your case:

| I need to… | Use |
|---|---|
| Make an LLM call | `Factory.ask/2` or `Factory.ask_with_config/4` — never call ReqLLM or Jido directly |
| Execute a configured agent | `Executor.run/2` — handles server presence, config loading, factory delegation |
| Build a response from pipeline output | `Outgoing.from_pipeline_result/2` — do not construct response maps inline |
| Store or read conversation turns | `Zaq.Agent.History` — `build/1`, `entry_key/2` |
| Resolve provider credentials or endpoint URL | `get_ai_provider_credential/1` then `Factory.build_model_spec/1` — nowhere else |
| Translate a provider name to a ReqLLM atom | `ProviderSpec.reqllm_provider/1` — called by `Factory`; other modules must not call it directly |

If the existing entry point does not cover your case, **extend it** — do not create a parallel path.

---

## Module Responsibility Map

Use this to decide where new code belongs. When a function would violate the "Does NOT own" column, find the correct module first.

| Module | Owns | Does NOT own |
|---|---|---|
| `ProviderSpec` | Provider-atom normalisation (`reqllm_provider/1`), fixed-URL detection, base-URL injection, `build/1` for configured agents | Agent lifecycle, LLM calls, credential storage |
| `Factory` | Model spec assembly (`build_model_spec/0,1`), `ask/ask_with_config`, generation opts | Provider/URL logic (delegated to `ProviderSpec`), credential resolution, pipeline orchestration |
| `Executor` | Configured-agent lifecycle, config loading, factory delegation, `:answering` status broadcast | LLM call details, response struct construction |
| `StreamEvents` | Request-local stream reduction, realtime buffered updates, trace/tool capture, model/measurement extraction | Server lifecycle, provider config, persistence |
| `ServerManager` | `AgentServer` start/stop/lookup per configured agent id | Provider logic, URL handling, answer building, branching by agent type |
| `Pipeline` | Orchestration of retrieval → answering steps, hook dispatch | LLM calls, response struct construction, agent-type branches, status broadcasts |
| `Answering` | Answer extraction, `Result` struct, telemetry | Agent lifecycle, provider/credential details |
| `Api` | `NodeRouter` dispatch entrypoint, PromptGuard gate, `:validating` status broadcast, route decision | Business logic beyond routing |
| `Status` | Fire-and-forget status broadcast routed via NodeRouter to the BO node | Orchestration, agent lifecycle, UI logic, PubSub subscription |
| `History` | Conversation turn storage and retrieval helpers | LLM calls, pipeline logic |

**`ServerManager` state discipline**: state must be minimal. If a variable exists only to trigger future behavior, use `Process.send_after/3` instead of storing it in state.

**Security**: `nil` person_id is never an implicit permission grant. Any function that filters data by person must default `skip_permissions: false` and require an explicit opt-in for admin access:
```elixir
skip_permissions = Map.get(context, :skip_permissions, false)
# Never: skip_permissions = is_nil(person_id)
```

For person-scoped tools the identity must come from the **trusted execution context**,
never from LLM-supplied parameters: `ctx[:person_id]` on the chat path (set by the
pipeline from the channel-resolved author) or `ctx[:actor]` on the workflow path (set by
`ActionWrapper` from the run's `source_event`). An LLM-facing `person_id` parameter may
be honored only under `ctx[:skip_permissions] == true` (see
`Zaq.Agent.Tools.Accounts.History` for the reference implementation). Blank/empty-string
IDs never resolve to an identity.

---

## Pipeline Flow

```
User question (BO Chat / Channel)
  → Api.handle_event/3  (:run_pipeline)     ← role boundary; runs on agent node
      → PromptGuard.validate/1              ← blocks prompt injection (single gate)
      → Status.broadcast(:validating)       ← PubSub → ChatLive
      → identity resolution
      → route decision:

    [RAG path — no agent_selection]
      → Pipeline.run/2
          → Hooks.dispatch_sync(:retrieval, ...)
          → Retrieval.ask/2                 ← LLM rewrites question into queries (JSON)
              → Status.broadcast(:retrieving) ← PubSub → ChatLive
          → Hooks.dispatch_async(:retrieval_complete, ...)
          → Hooks.dispatch_sync(:answering, ...)
          → DocumentProcessor.query_extraction  ← ranked KB chunks
          → Executor.run/2  (agent_id: nil)
              → Status.broadcast(:answering)  ← PubSub → ChatLive
              → Factory.ask_with_config/4
              → StreamEvents.consume/3       ← realtime updates + trace/measurements
          → Hooks.dispatch_async(:answer_generated, ...)
          → Hooks.dispatch_async(:pipeline_complete, ...)

    [Configured-agent path — explicit agent_selection]
      → Executor.run/2  (agent_id: N)
          → Status.broadcast(:answering)    ← PubSub → ChatLive
          → Factory.ask_with_config/4
          → StreamEvents.consume/3           ← realtime updates + trace/measurements

  → %Outgoing{} → Router.deliver → WebBridge.send_reply → PubSub → ChatLive

  On no-answer: emits qa.no_answer.count telemetry
```

### Status broadcast ownership

Each module broadcasts its own stage — orchestrators broadcast nothing:

| Stage | Owner | Notes |
|---|---|---|
| `:validating` | `Api` | after PromptGuard passes; before routing |
| `:retrieving` | `Retrieval` | at start of `ask/2`, before LLM call |
| `:answering` | `Executor` | before `Factory.ask_with_config`; fires on both paths |

---

## Modules

### Pipeline (`Zaq.Agent.Pipeline`)
- `run/2` — shared answering pipeline for all retrieval channels (Mattermost, Slack, chat widget, …). **Deprecated as a direct caller API**: invoke through `Zaq.Agent.Api` via `NodeRouter.dispatch/1` (`:run_pipeline`) instead of calling `Pipeline.run/2` from feature code.
- Runs: retrieve → extract → answer → output safety check (input validation happens in `Api` before routing)
- Returns a stable map: `:answer`, `:confidence_score`, `:latency_ms`, `:prompt_tokens`, `:completion_tokens`, `:total_tokens`, `:error`
- On no-answer emits telemetry via `Zaq.Engine.Telemetry.record("qa.no_answer.count", 1, ...)`
- Dispatches hook events: `:retrieval`, `:retrieval_complete`, `:answering`, `:answer_generated`, `:pipeline_complete`
- All sub-modules injectable via opts (`:hooks`, `:node_router`, `:retrieval`, `:document_processor`, `:answering`, `:prompt_guard`, `:prompt_template`)
- Pipeline broadcasts **no status events** — each sub-module owns its own stage signal
- `telemetry_dimensions` opt: map of extra dimensions forwarded to telemetry metrics

### Status (`Zaq.Agent.Status`)
- `broadcast/4` — fire-and-forget status broadcast for pipeline stage transitions
- Accepts `%Incoming{}`, a `%{session_id: _, request_id: _}` context map, or `nil`; 4th arg is a `node_router` module (defaults to `Zaq.NodeRouter`)
- Routes the PubSub broadcast via `NodeRouter.dispatch/1` to BO so the broadcast executes on the BO node where `ChatLive` is subscribed — safe for multi-node deployments where the agent node and BO node are separate
- Broadcasts `{:status_update, request_id, stage, message}` to `"chat:<session_id>"` — same topic and format `ChatLive` already handles
- Nil or incomplete context is silently ignored — missing context never crashes the pipeline
- Injectable via `status_module:` opt in `Api` and `Executor`; inject a `FakeNodeRouter` (calls `apply/3` locally) in unit tests to avoid real RPC

### Agent API + Executor
- `Zaq.Agent.Api` is the role boundary entrypoint used by `NodeRouter.dispatch/1`
- `:run_pipeline` is a single entrypoint with three sequential responsibilities:
  1. **Guard**: `PromptGuard.validate/1` — if it fails, returns a guard-blocked `Outgoing` through the standard persist + channels return-hop path (same delivery flow as regular pipeline responses)
  2. **Signal**: `Status.broadcast(:validating)` — fired once after the guard passes, before routing
  3. **Route**: no `event.assigns["agent_selection"]` → `Pipeline.run/2`; explicit `agent_id` → `Executor.run/2`
- Both `prompt_guard:` and `status_module:` are injectable via event opts for testing
- `Zaq.Agent.Executor` loads the configured agent (or default answering agent), ensures server presence, broadcasts `:answering`, delegates dispatch to `Factory`, then consumes stream events through `StreamEvents`
- **Auditability rule (mandatory):** channel delivery is allowed only after persistence succeeds. In `Zaq.Agent.Api`, `persist_from_incoming` must complete successfully before scheduling the `:deliver_outgoing` return hop. If persistence fails, the API must return `{:error, {:persist_failed, reason}}` and must not dispatch to Channels.
- Runtime sync actions also enter through `Zaq.Agent.Api` and call `Zaq.Agent.RuntimeSync`:
  - `:configured_agent_updated`
  - `:configured_agent_deleted`
  - `:mcp_endpoint_updated`

### Configured Agents (`Zaq.Agent` context)
- Schema: `Zaq.Agent.ConfiguredAgent` (`configured_agents` table)
- BO CRUD route: `/bo/agents`
- Chat selector route: `/bo/chat` top bar dropdown
- Key fields: `name`, `job`, `model`, `credential_id`, `enabled_tool_keys`, `enabled_mcp_endpoint_ids`, `conversation_enabled`, `strategy`, `advanced_options`, `active`

### Runtime Sync (`Zaq.Agent.RuntimeSync`)
- Owns runtime orchestration after configured-agent and MCP endpoint mutations.
- Responsibilities:
  - configured agent create/update/delete runtime handling
  - MCP endpoint update fanout to impacted configured agents
  - hydration/sync of MCP assignments into running agent runtimes
  - unsync of MCP assignments when endpoint is disabled/deleted
- Exposes a single orchestration boundary so BO code dispatches events and does not call low-level runtime modules directly.

### MCP Context (`Zaq.Agent.MCP`)
- Context boundary for MCP endpoint CRUD and related orchestration entrypoints
- Works with RuntimeSync/MCP runtime modules instead of exposing low-level runtime operations to BO callers

### MCP Runtime IDs + Signal Adapter (`Zaq.Agent.MCP.Runtime`)
- Owns deterministic runtime endpoint id mapping:
  - DB endpoint id `123` -> runtime id `:"mcp_123"`
  - runtime id `:"mcp_123"` -> DB endpoint id `123`
- Owns runtime registration/sync/unsync adapters used by RuntimeSync.
- Implements the MCP signal adapter pattern: BO/system-config changes produce one agent-domain event (`:mcp_endpoint_updated`) that RuntimeSync translates into runtime operations.

### MCP Endpoint Schema (`Zaq.Agent.MCP.Endpoint`)
- Ecto schema for persisted MCP endpoints and runtime linkage fields
- Source of truth for endpoint records used by runtime sync

### MCP Signal Adapter (`Zaq.Agent.MCP.SignalAdapter`)
- Normalizes MCP update/delete signals before runtime sync orchestration
- Keeps BO/system-config mutation payload contracts stable for agent-runtime consumers

### Tool Registry (`Zaq.Agent.Tools.Registry`)
- Code-defined allowlist of tool keys and modules
- Runtime validation of selected tools
- Capability check via `LLMDB` (`capabilities[:tools]`)

### DataSource Success Payload Contract
- Any successful DataSource bridge callback must return one of these shapes only:
  - `{:ok, %Zaq.Contracts.RecordPage{...}}`
  - `{:ok, %Zaq.Contracts.Record{...}}`
  - `{:ok, map}` where the map wraps at least one `%Zaq.Contracts.Record{}` or `%Zaq.Contracts.RecordPage{}` value (for example `%{record: %Record{...}}`, `%{result: %RecordPage{...}}`, `%{status: "updated", record: %Record{...}}`).
- Returning raw provider payload maps as success responses is not allowed.
- This contract applies to new operations added in any module implementing `@behaviour Zaq.Channels.DataSourceBridge`.

### Built-in Agent Tools (`Zaq.Agent.Tools.SearchKnowledgeBase`, `Zaq.Agent.Tools.ListKnowledgeBaseFiles`)
- Tool implementations exposed to configured agents through `Tools.Registry`
- Availability remains controlled by enabled tool keys and provider capabilities

### Conversation Recall Tool (`Zaq.Agent.Tools.Accounts.History`, key `accounts.fetch_history`)
- Recalls the requesting person's past conversations by topic (`query`) and/or time
  window (`last_n_days` integer or ISO `from_date`/`to_date`), grouped per conversation
  with titles
- Identity is resolved from the trusted context (chat `ctx[:person_id]`, workflow
  `ctx[:actor]`); the `person_id` parameter is honored only on `skip_permissions` runs
- Doubles as a workflow action (`use Zaq.Engine.Workflows.Action`)

### Runtime Factory (`Zaq.Agent.Factory`)
- Standard runtime agent for all configured agents
- Supports per-request runtime tool/module selection and LLM options
- Supports runtime server configuration via system-prompt signal
- `runtime_config/1` is the canonical runtime-config builder (other modules should delegate, not duplicate logic)

### Server Manager (`Zaq.Agent.ServerManager`)
- Ensures server presence and reconciles tracked runtimes.
- Runtime lifecycle details (hot patch vs stop-only + lazy restart) are documented in [Architecture → Configured Agent Runtime Lifecycle](../architecture.md#configured-agent-runtime-lifecycle).
- Channel reachability policy for `conversation_enabled` is documented in [Channels Service → Conversation Agent Eligibility](channels.md#conversation-agent-eligibility).

### Runtime Sync Strategy (Hot Patch vs Restart)
- Runtime sync strategy is summarized in [Architecture → Configured Agent Runtime Lifecycle](../architecture.md#configured-agent-runtime-lifecycle).

### Atom Safety + Capacity Guards
- MCP runtime endpoint ids create atoms at runtime; safeguards are enforced before registration.
- Guardrails:
  - atom-memory usage threshold: `>= 85%` blocks new endpoint atom creation
  - endpoint hard cap: `2000` MCP endpoints
- These checks are implemented in `Zaq.Agent.MCP.Runtime` and must remain centralized there.

### Stream Events (`Zaq.Agent.StreamEvents`)
- Reduces `Jido.AI.Agent.ask_stream/3` events into one request result consumed by `Executor`.
- Broadcasts buffered realtime updates through `Status.broadcast/4` so all channels keep using the same channel update flow.
- Captures a uniform top-level message trace list, including content/reasoning segments and tool calls.
- Extracts `measurements`, `model`, and sanitized `agent` metadata from the stream result; token counts come from stream usage.
- Registers request-local inspection state in `Zaq.Agent.RequestRegistry` for inspect/steer/inject actions.

### Provider Spec (`Zaq.Agent.ProviderSpec`)
- Central home for provider normalization (`reqllm_provider/1`) and fixed-URL policy (`fixed_url_provider?/1`)
- Builds provider spec maps and generation options consumed by `Factory`
- Resolves configured-agent provider credentials through `Zaq.System.get_ai_provider_credential/1`
- Keeps OpenAI-compatible fallback behavior centralized so other modules do not branch by provider

### Query Rewriting (`Zaq.Agent.Retrieval`)
- Rewrites user question into structured JSON search queries via LLM
- Uses DB-managed prompt template (`"retrieval"` slug)
- Supports conversation history
- Broadcasts `:retrieving` via `Status.broadcast/4` at the start of `ask/2` using `status_context:` opt (passed by Pipeline as `%{session_id, request_id}`) and `node_router:` opt (defaults to `Zaq.NodeRouter`)
- Returns string-keyed map — callers (Pipeline) normalize to atom keys internally

### Query Filters (`Zaq.Agent.QueryFilters`)
- Canonical helper module for retrieval filter normalization and composition
- Prevents ad-hoc filter shaping across retrieval callers

### Response Formulation (`Zaq.Agent.Answering`)
- Generates natural language answers from retrieved context
- Uses DB-managed prompt template (`"answering"` slug)
- Optionally computes confidence score from logprobs via `LogprobsAnalyzer.confidence_from_metadata/2` (when supported)
- Emits telemetry: `qa.answer.latency_ms`, `qa.tokens.prompt`, `qa.tokens.completion`, `qa.tokens.total`, `qa.answer.confidence`, `qa.answer.confidence.bucket.*`
- Returns `%Zaq.Agent.Answering.Result{}` struct
- `no_answer?/1` — detects when LLM signals it couldn't find relevant info; checks against a fixed set of signal phrases (e.g. `"i don't have"`, `"no relevant"`, `"outside my knowledge"`)
- `clean_answer/1` — strips markdown fences and surrounding quotes
- `normalize_result/1` — converts legacy map or struct to `%Result{}`; handles atom-keyed maps, string-keyed maps, and bare strings

### Answering Result (`Zaq.Agent.Answering.Result`)
- Canonical struct for answer payloads across all callers and channels
- Fields: `:answer`, `:confidence_score`, `:latency_ms`, `:prompt_tokens`, `:completion_tokens`, `:total_tokens`

### Citation Normalizer (`Zaq.Agent.CitationNormalizer`)
- `normalize/3` — rewrites inline `[[source:path]]` and `[[memory:label]]` markers to numbered citation references
- Validates sources against the retrieved chunk sources; strips unknown markers
- Returns `%{body: String.t(), sources: [normalized_reference()]}`
- Supports custom memory labels via opts (defaults: `"llm-general-knowledge"`, `"llm-reasoning-inference"`, `"llm-linguistic-normalization"`)

### Conversation History (`Zaq.Agent.History`)
- `entry_key/2` — builds string keys for history map entries in the form `"<iso8601>_<index>_<role>"`
- `build/1` — converts history map to sorted `[LangChain.Message.t()]` list; handles `:user` and `:bot` roles

### History Loader (`Zaq.Agent.HistoryLoader`)
- Loads initial context for runtime agent cold starts
- Supports conversation-scoped and person/provider-scoped history hydration
- Used by `Factory.build_initial_context/2`

### Prompt Security (`Zaq.Agent.PromptGuard`)
- `validate/1` — blocks prompt injection and persona hijacking at entry point
- `output_safe?/1` — detects system prompt leakage in LLM output
- Regex-based detection: injection patterns, jailbreak patterns, data exfiltration
- Role-play signal counting with configurable threshold
- Runs on the BO node (does not need to be routed)

### Confidence Scoring (`Zaq.Agent.LogprobsAnalyzer`)
- Converts logprobs to probabilities via `exp(logprob)`
- `calculate_confidence/2` — average confidence across all tokens; accepts `logprobs_content` list and optional `round` flag
- `confidence_from_metadata/2` — extracts `logprobs.content` from LangChain message metadata and calls `calculate_confidence/2`; used directly by `Answering`
- `confidence_from_metadata_or_nil/2` — convenience variant that returns `nil` on error instead of `{:error, reason}`
- `token_confidences/1` — per-token confidence list with alternatives; defined but not called by the pipeline
- Only invoked when logprobs are enabled for the active provider/options path

### Token Estimation (`Zaq.Agent.TokenEstimator`)
- Word-count heuristic: `word_count × 1.3`, rounded up
- Used by `DocumentChunker` for section sizing and `DocumentProcessor` for context window limits
- Lightweight — no Bumblebee/Nx dependency

### Idle Lifecycle (`Zaq.Agent.IdleLifecycle`)
- Runtime idle policy helper used by server lifecycle management
- Centralizes idle-time behavior choices to avoid per-caller drift

### Chunk Title Generation (`Zaq.Agent.ChunkTitle`)
- Generates concise, searchable titles (max 8 words) for document chunks via LLM
- Focuses on named entities, dates, product names to improve embedding quality
- Implements `Zaq.Agent.ChunkTitleBehaviour` (injectable for tests)
- Called during ingestion by `DocumentProcessor.store_chunk_with_metadata/3`

### Prompt Templates (`Zaq.Agent.PromptTemplate`)
- Ecto schema backed by `prompt_templates` DB table
- Editable via Back Office (`prompt_templates_live`)
- Slugs: `"retrieval"`, `"answering"`, `"chunk_title"`
- EEx-style placeholders interpolated via `render/2`
- `get_active!/1` — returns body string, raises if slug not found; agents depend on templates being seeded
- `get_active/1` — returns `{:ok, body} | {:error, :not_found}` without raising
- `get_by_slug/1` — returns full record (not just body)
- `list/0` — returns all templates ordered by slug
- `create/1`, `update/2` — CRUD used by the Back Office LiveView
- Default templates are seeded by migration `20260316204749_seed_default_prompt_templates`

---

## Files

```
lib/zaq/agent/
├── configured_agent.ex          # Ecto schema for BO-managed configured agents
├── executor.ex                  # Selected-agent execution path; broadcasts :answering
├── answering/
│   └── result.ex               # Canonical answer result struct
├── answering.ex                # Response formulation constants and helpers
├── chunk_title.ex              # LLM-generated chunk titles for ingestion
├── chunk_title_behaviour.ex    # Behaviour for ChunkTitle (allows mocking)
├── citation_normalizer.ex      # Rewrites [[source:...]] markers to numbered refs
├── factory.ex                  # Runtime-configured standard Jido agent
├── history.ex                  # Conversation history map helpers
├── history_loader.ex           # Loads initial runtime context from stored history
├── idle_lifecycle.ex           # Runtime idle-lifecycle policy helpers
├── logprobs_analyzer.ex        # Confidence scoring from logprobs
├── mcp.ex                      # MCP endpoint context + orchestration
├── mcp/
│   ├── endpoint.ex             # MCP endpoint schema
│   ├── runtime.ex              # MCP runtime id mapping, guards, registration helpers
│   └── signal_adapter.ex       # MCP signal normalization for RuntimeSync
├── pipeline.ex                 # Unified answering pipeline for all channels
├── prompt_guard.ex             # Prompt injection + leakage protection
├── prompt_template.ex          # Ecto schema + context for DB-stored prompts
├── provider_spec.ex            # Provider normalization + model spec policy
├── query_filters.ex            # Retrieval query filter helpers
├── request_registry.ex         # Request-local inspection state
├── retrieval.ex                # Query rewriting agent; broadcasts :retrieving
├── runtime_sync.ex             # Runtime orchestration for agent + MCP mutations
├── stream_events.ex            # Stream reduction, realtime updates, trace capture
├── server_manager.ex           # Ensures one AgentServer per configured agent id
├── status.ex                   # Fire-and-forget PubSub status broadcast
├── supervisor.ex               # Agent role supervisor with dynamic AgentServer tree
├── tools/
│   ├── list_knowledge_base_files.ex # Built-in tool: list KB files
│   ├── registry.ex             # Code-defined tool allowlist and capability checks
│   └── search_knowledge_base.ex # Built-in tool: semantic KB search
└── token_estimator.ex          # Word-based token count heuristic
```

---

## Configuration

- Managed in Back Office at `/bo/system-config`
- Persisted in `system_configs`
- Loaded at runtime via `Zaq.System.get_llm_config/0`

LLM keys stored in System Config:

- `llm.credential_id`
- `llm.model`
- `llm.temperature`
- `llm.top_p`
- `llm.supports_logprobs`
- `llm.supports_json_mode`
- `llm.max_context_window`
- `llm.distance_threshold`

Connection fields (`provider`, `endpoint`, `api_key`) are resolved from
`ai_provider_credentials` using `llm.credential_id`.

---

## Key Design Decisions

- **`Api` is the security boundary** — `PromptGuard.validate/1` runs once in `Api` before routing; neither `Pipeline` nor `Executor` call it for input validation; Pipeline still calls `output_safe?/1` on the LLM response
- **Status ownership follows work ownership** — each module broadcasts its own stage signal (`Api` → `:validating`, `Retrieval` → `:retrieving`, `Executor` → `:answering`); orchestrators (`Pipeline`) broadcast nothing
- **Status broadcasts route via NodeRouter** — `Status.broadcast/4` routes through `NodeRouter.dispatch/1` so the PubSub broadcast runs on the BO node where `ChatLive` is subscribed; the 4th `node_router` arg is injectable (default `Zaq.NodeRouter`) so unit tests pass a `FakeNodeRouter` that calls `apply/3` locally
- **`Api` is the only supported entrypoint** — route to `Zaq.Agent.Api` (`:run_pipeline`) via `Zaq.Agent.Events.build_and_dispatch_invoke_event/3`; direct `Pipeline.run/2` calls are deprecated outside agent internals
- **All sub-modules injectable** — Pipeline accepts module overrides for every dependency, enabling isolated unit tests without mocking globals
- **Hook system** — sync and async hooks dispatched at pipeline stage boundaries; external features attach via hooks without modifying core pipeline logic
- **Provider policy has one home** — provider normalization and URL behavior live in `ProviderSpec`; callers use `Factory` entrypoints only
- **Prompt templates in DB** — editable at runtime without deploys; agents raise if missing
- **ChunkTitle is injectable** — `Application.get_env(:zaq, :chunk_title_module, Zaq.Agent.ChunkTitle)` allows test mocking
- **Confidence is optional** — gracefully skipped when `supports_logprobs?` is false
- **NodeRouter for cross-node calls** — BO never calls agent modules directly; use `Zaq.Agent.Events` helpers to build/dispatch invoke events instead of hand-rolling `%Zaq.Event{}`
- **Answering.Result struct** — canonical shape shared across channels; `normalize_result/1` converts legacy maps

### Harness-Critical Checks for Coding Agents
- **Doc ↔ code parity**: service docs must only reference real modules.
- **Single execution path**: extend `Factory`/`Executor`; never add parallel LLM paths.
- **Ownership-aligned telemetry**: avoid duplicate emitters; module doing work emits the stage/metric.
- **Security defaults**: nil identity is never implicit admin; explicit opt-in only.
- **MCP runtime safety**: keep runtime id mapping and atom guards centralized in `Zaq.Agent.MCP.Runtime`.
- **Property testing for invariants**: follow `docs/testing-approach.md`; add property tests for normalization, safety defaults, and deterministic mappings when agent code changes.

---

## What's Left

### Should Do
- [ ] Knowledge gap tracking (detect unanswered questions, store for review)
- [ ] Classifier module (route questions to different agents or topics)
- [ ] Add Agent GenServers to `Zaq.Agent.Supervisor` when stateful components are needed

### Nice to Have
- [ ] Streaming responses for long answers
- [ ] Per-session LLM config overrides
- [ ] HTML parser for `DocumentChunker` (currently raises `"not implemented"`)
