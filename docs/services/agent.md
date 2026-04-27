# Agent Service

## Overview

The Agent service is the AI layer of ZAQ. It handles query rewriting, response formulation,
confidence scoring, prompt security, and chunk title generation during ingestion.

Core pipeline modules remain stateless, but configured agents are now runtime-managed.
`Zaq.Agent.Supervisor` starts:
- `DynamicSupervisor` (`Zaq.Agent.AgentServerSupervisor`)
- `Zaq.Agent.ServerManager`

`ServerManager` maintains one long-lived `Jido.AgentServer` per configured agent id.

LLM configuration is centralized in `Zaq.Agent.LLM` — no other module reads
provider details directly.

**Important**: Agent modules must never be called directly from BO LiveViews.
All calls from BO go through `Zaq.NodeRouter` so they work correctly in both
single-node and multi-node deployments. New routing should use
`NodeRouter.dispatch/1` with `%Zaq.Event{next_hop: %Zaq.EventHop{destination: :agent}}`.

---

## Entry Point Decision Tree

Before writing any new agent-service code, verify which entry point already covers your case:

| I need to… | Use |
|---|---|
| Make an LLM call | `Factory.ask/2` or `Factory.ask_with_config/2` — never call ReqLLM or Jido directly |
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
| `Executor` | Configured-agent lifecycle, config loading, factory delegation | LLM call details, response struct construction |
| `ServerManager` | `AgentServer` start/stop/lookup per configured agent id | Provider logic, URL handling, answer building, branching by agent type |
| `Pipeline` | Orchestration of retrieval → answering steps, hook dispatch | LLM calls, response struct construction, agent-type branches |
| `Answering` | Answer extraction, `Result` struct, telemetry | Agent lifecycle, provider/credential details |
| `Api` | `NodeRouter` dispatch entrypoint, role boundary | Business logic of any kind |
| `History` | Conversation turn storage and retrieval helpers | LLM calls, pipeline logic |

**`ServerManager` state discipline**: state must be minimal. If a variable exists only to trigger future behavior, use `Process.send_after/3` instead of storing it in state.

**Security**: `nil` person_id is never an implicit permission grant. Any function that filters data by person must default `skip_permissions: false` and require an explicit opt-in for admin access:
```elixir
skip_permissions = Map.get(context, :skip_permissions, false)
# Never: skip_permissions = is_nil(person_id)
```

---

## Pipeline Flow

```
User question (BO Chat / Channel)
  → Pipeline.run/2                          ← unified entrypoint for all channels
      → PromptGuard.validate/1              ← blocks prompt injection (runs on BO node)
      → Hooks.dispatch_sync(:retrieval, ...)
      → NodeRouter.dispatch(%Zaq.Event{...destination: :agent...})
          (action: :invoke / :run_pipeline)
                                         ← routed to agent node
          → Retrieval.ask/2                 ← LLM rewrites question into search queries (JSON)
      → Hooks.dispatch_async(:retrieval_complete, ...)
      → Hooks.dispatch_sync(:answering, ...)
      → NodeRouter.dispatch(%Zaq.Event{...destination: :ingestion...})
           → hybrid search, returns ranked chunks
      → NodeRouter.dispatch(%Zaq.Event{...destination: :agent...})
                                         ← routed to agent node
          → Answering.ask/2                 ← LLM formulates answer from context
      → PromptGuard.output_safe?/1          ← checks for system prompt leakage
      → Hooks.dispatch_async(:answer_generated, ...)
      → Hooks.dispatch_async(:pipeline_complete, ...)
  → %{answer, confidence_score, latency_ms, prompt_tokens, ...}

  On no-answer: sets knowledge_gap: true, emits qa.no_answer.count telemetry
```

---

## Modules

### Pipeline (`Zaq.Agent.Pipeline`)
- `run/2` — shared answering pipeline for all retrieval channels (Mattermost, Slack, chat widget, …)
- Runs: validate → retrieve → extract → answer → safety check
- Returns a stable map: `:answer`, `:confidence_score`, `:latency_ms`, `:prompt_tokens`, `:completion_tokens`, `:total_tokens`, `:error`
- On no-answer, sets `knowledge_gap: true` and emits a telemetry event via `Zaq.Engine.Telemetry.record("qa.no_answer.count", 1, ...)`
- Dispatches hook events: `:before_retrieval`, `:after_retrieval`, `:before_answering`, `:after_answer_generated`, `:after_pipeline_complete`
- All sub-modules are injectable via opts for testing (`:hooks`, `:node_router`, `:retrieval`, `:document_processor`, `:answering`, `:prompt_guard`, `:prompt_template`)
- `on_status` opt: 2-arity `fn(stage, message) :: :ok` callback for LiveView progress updates
- `telemetry_dimensions` opt: map of extra dimensions forwarded to telemetry metrics

### Agent API + Executor
- `Zaq.Agent.Api` is the role boundary entrypoint used by `NodeRouter.dispatch/1`
- `:run_pipeline` stays a single entrypoint and branches on event metadata:
  - no `event.assigns["agent_selection"]` -> `Pipeline.run/2`
  - explicit `event.assigns["agent_selection"]["agent_id"]` -> `Zaq.Agent.Executor.run/2`
- `Zaq.Agent.Executor` loads and validates selected configured agent, ensures server presence, and executes through `Zaq.Agent.Factory`

### Configured Agents (`Zaq.Agent` context)
- Schema: `Zaq.Agent.ConfiguredAgent` (`configured_agents` table)
- BO CRUD route: `/bo/agents`
- Chat selector route: `/bo/chat` top bar dropdown
- Key fields: `name`, `job`, `model`, `credential_id`, `enabled_tool_keys`, `conversation_enabled`, `strategy`, `advanced_options`, `active`

### Tool Registry (`Zaq.Agent.Tools.Registry`)
- Code-defined allowlist of tool keys and modules
- Runtime validation of selected tools
- Capability check via `LLMDB` (`capabilities[:tools]`)

### Runtime Factory (`Zaq.Agent.Factory`)
- Standard runtime agent for all configured agents
- Supports per-request runtime tool/module selection and LLM options
- Supports runtime server configuration via system-prompt signal

### Jido Observability Logger (`Zaq.Agent.JidoObservabilityLogger`)
- Attaches to Jido AI telemetry events (`request`, `llm`, `tool`, `tool.execute`) on the agent node
- Writes level-aware console logs:
  - `info`: compact lifecycle summaries
  - `debug`: sanitized payload details
  - `warning/error`: timeout and failure paths
- Config (`:zaq, :jido_observability_logger`): `enabled`, `include_llm_deltas`, `max_payload_chars`

### LLM Configuration (`Zaq.Agent.LLM`)
- Centralized config reader for all agent modules
- Supports any OpenAI-compatible endpoint (Scaleway, OpenAI, Ollama, vLLM, LocalAI, llama.cpp)
- `chat_config/1` returns a map ready to pass to LangChain's `ChatOpenAI`
- Feature flags: `supports_logprobs?/0`, `supports_json_mode?/0`
- Config keys: `endpoint`, `api_key`, `model`, `temperature`, `top_p`

### LLM Runner (`Zaq.Agent.LLMRunner`)
- Shared low-level wrapper around LangChain's `LLMChain`
- `run/1` — accepts a keyword list with `:llm_config`, `:system_prompt`, `:history`, `:question`; returns `{:ok, chain} | {:error, String.t()}`
- `content/1` / `content_result/1` — extract assistant response text from a chain result
- Deduplicates empty-content log warnings via ETS (`@empty_content_log_ttl_ms = 60_000`)
- Emits `:telemetry.execute([:zaq, :agent, :llm_runner, :empty_content], ...)` on empty responses

### Query Rewriting (`Zaq.Agent.Retrieval`)
- Rewrites user question into structured JSON search queries via LLM
- Uses DB-managed prompt template (`"retrieval"` slug)
- Supports conversation history
- Enables JSON mode when `LLM.supports_json_mode?/0` is true
- Returns string-keyed map — callers (Pipeline) normalize to atom keys internally

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
- Only invoked when `LLM.supports_logprobs?/0` is true

### Token Estimation (`Zaq.Agent.TokenEstimator`)
- Word-count heuristic: `word_count × 1.3`, rounded up
- Used by `DocumentChunker` for section sizing and `DocumentProcessor` for context window limits
- Lightweight — no Bumblebee/Nx dependency

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
├── executor.ex                  # Selected-agent execution path
├── answering/
│   └── result.ex               # Canonical answer result struct
├── answering.ex                # Response formulation via LLM
├── chunk_title.ex              # LLM-generated chunk titles for ingestion
├── chunk_title_behaviour.ex    # Behaviour for ChunkTitle (allows mocking)
├── citation_normalizer.ex      # Rewrites [[source:...]] markers to numbered refs
├── factory.ex                  # Runtime-configured standard Jido agent
├── history.ex                  # Conversation history map helpers
├── jido_observability_logger.ex # Console logger for Jido AI telemetry events
├── llm.ex                      # Centralized LLM config reader
├── llm_runner.ex               # Low-level LangChain LLMChain wrapper
├── logprobs_analyzer.ex        # Confidence scoring from logprobs
├── pipeline.ex                 # Unified answering pipeline for all channels
├── prompt_guard.ex             # Prompt injection + leakage protection
├── prompt_template.ex          # Ecto schema + context for DB-stored prompts
├── retrieval.ex                # Query rewriting agent
├── server_manager.ex           # Ensures one AgentServer per configured agent id
├── supervisor.ex               # Agent role supervisor with dynamic AgentServer tree
├── tools/
│   └── registry.ex             # Code-defined tool allowlist and capability checks
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

- **Pipeline is the single entrypoint** — all channels call `Zaq.Agent.Pipeline.run/2`; no channel implements its own retrieve-answer logic
- **All sub-modules injectable** — Pipeline accepts module overrides for every dependency, enabling isolated unit tests without mocking globals
- **Hook system** — sync and async hooks dispatched at pipeline stage boundaries; external features attach via hooks without modifying core pipeline logic
- **No hardcoded providers** — everything goes through `Zaq.Agent.LLM`
- **LangChain via `ChatOpenAI`** — all LLM calls use LangChain's OpenAI-compatible adapter, wrapped by `LLMRunner`
- **Prompt templates in DB** — editable at runtime without deploys; agents raise if missing
- **ChunkTitle is injectable** — `Application.get_env(:zaq, :chunk_title_module, Zaq.Agent.ChunkTitle)` allows test mocking
- **Confidence is optional** — gracefully skipped when `supports_logprobs?` is false
- **NodeRouter for cross-node calls** — BO never calls agent modules directly; prefer `NodeRouter.dispatch/1` (`call/4` is deprecated compatibility)
- **Answering.Result struct** — canonical shape shared across channels; `normalize_result/1` converts legacy maps

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
