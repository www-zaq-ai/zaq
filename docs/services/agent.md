# Agent Service

## Overview

The Agent service is the AI layer of ZAQ. It handles query rewriting, response formulation,
confidence scoring, prompt security, and chunk title generation during ingestion.

All agent modules are stateless — they are plain modules with no GenServers.
The `Zaq.Agent.Supervisor` exists but currently starts no children.

LLM configuration is centralized in `Zaq.Agent.LLM` — no other module reads
provider details directly.

**Important**: Agent modules must never be called directly from BO LiveViews.
All calls from BO go through `Zaq.NodeRouter.call(:agent, ...)` so they work
correctly in both single-node and multi-node deployments.

---

## Pipeline Flow

```
User question (BO Chat)
  → PromptGuard.validate/1              ← blocks prompt injection (runs on BO node)
  → NodeRouter.call(:agent, Retrieval)  ← routed to agent node
      → Retrieval.ask/2                 ← LLM rewrites question into search queries (JSON)
  → NodeRouter.call(:ingestion, DocumentProcessor.query_extraction)
      → hybrid search, returns ranked chunks
  → NodeRouter.call(:agent, Answering)  ← routed to agent node
      → Answering.ask/2                 ← LLM formulates answer from context
  → PromptGuard.output_safe?/1          ← checks for system prompt leakage (runs on BO node)
  → User
```

---

## What's Done

### LLM Configuration (`Zaq.Agent.LLM`)
- Centralized config reader for all agent modules
- Supports any OpenAI-compatible endpoint (Scaleway, OpenAI, Ollama, vLLM, LocalAI, llama.cpp)
- `chat_config/1` returns a map ready to pass to LangChain's `ChatOpenAI`
- Feature flags: `supports_logprobs?/0`, `supports_json_mode?/0`
- Config keys: `endpoint`, `api_key`, `model`, `temperature`, `top_p`

### Query Rewriting (`Zaq.Agent.Retrieval`)
- Rewrites user question into structured JSON search queries via LLM
- Uses DB-managed prompt template (`"retrieval"` slug)
- Supports conversation history
- Enables JSON mode when `LLM.supports_json_mode?/0` is true
- Returns string-keyed map — callers must normalize to atom keys

### Response Formulation (`Zaq.Agent.Answering`)
- Generates natural language answers from retrieved context
- Uses DB-managed prompt template (`"answering"` slug)
- Optionally computes confidence score from logprobs (when supported)
- Returns `{:ok, %{answer: string, confidence: %{score: float}}}` or `{:ok, string}`
- `no_answer?/1` — detects when LLM signals it couldn't find relevant info
- `clean_answer/1` — strips markdown fences and surrounding quotes

### Prompt Security (`Zaq.Agent.PromptGuard`)
- `validate/1` — blocks prompt injection and persona hijacking at entry point
- `output_safe?/1` — detects system prompt leakage in LLM output
- Regex-based detection: injection patterns, jailbreak patterns, data exfiltration
- Role-play signal counting with configurable threshold
- Runs on the BO node (does not need to be routed)

### Confidence Scoring (`Zaq.Agent.LogprobsAnalyzer`)
- Converts logprobs to probabilities via `exp(logprob)`
- `calculate_confidence/2` — average confidence across all tokens
- `token_confidences/1` — per-token confidence with alternatives
- Only used when `LLM.supports_logprobs?/0` is true

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
- `get_active!/1` raises if slug not found — agents depend on templates being seeded
- Default templates are seeded by migration `20260316204749_seed_default_prompt_templates`

---

## Files

```
lib/zaq/agent/
├── answering.ex            # Response formulation via LLM
├── chunk_title.ex          # LLM-generated chunk titles for ingestion
├── chunk_title_behaviour.ex # Behaviour for ChunkTitle (allows mocking)
├── llm.ex                  # Centralized LLM config reader
├── logprobs_analyzer.ex    # Confidence scoring from logprobs
├── prompt_guard.ex         # Prompt injection + leakage protection
├── prompt_template.ex      # Ecto schema + context for DB-stored prompts
├── retrieval.ex            # Query rewriting agent
├── supervisor.ex           # Placeholder supervisor (no children yet)
└── token_estimator.ex      # Word-based token count heuristic
```

---

## Configuration

- Managed in Back Office at `/bo/system-config`
- Persisted in `system_configs`
- Loaded at runtime via `Zaq.System.get_llm_config/0`

LLM keys stored in System Config:

- `llm.provider`
- `llm.endpoint`
- `llm.api_key`
- `llm.model`
- `llm.temperature`
- `llm.top_p`
- `llm.supports_logprobs`
- `llm.supports_json_mode`
- `llm.max_context_window`
- `llm.distance_threshold`

---

## Key Design Decisions

- **No hardcoded providers** — everything goes through `Zaq.Agent.LLM`
- **LangChain via `ChatOpenAI`** — all LLM calls use LangChain's OpenAI-compatible adapter
- **Prompt templates in DB** — editable at runtime without deploys; agents raise if missing
- **ChunkTitle is injectable** — `Application.get_env(:zaq, :chunk_title_module, Zaq.Agent.ChunkTitle)` allows test mocking
- **Confidence is optional** — gracefully skipped when `supports_logprobs?` is false
- **NodeRouter for cross-node calls** — BO never calls agent modules directly; always via `NodeRouter.call(:agent, ...)`
- **Retrieval returns string keys** — callers (e.g. chat) are responsible for normalizing to atom keys after the RPC call

---

## What's Left

### Must Do
- [ ] Implement query extraction integration (connect Retrieval output → DocumentProcessor → Answering)

### Should Do
- [ ] Knowledge gap tracking (detect unanswered questions, store for review)
- [ ] Classifier module (route questions to different agents or topics)
- [ ] Add Agent GenServers to `Zaq.Agent.Supervisor` when stateful components are needed

### Nice to Have
- [ ] Streaming responses for long answers
- [ ] Per-session LLM config overrides
- [ ] HTML parser for `DocumentChunker` (currently raises `"not implemented"`)
