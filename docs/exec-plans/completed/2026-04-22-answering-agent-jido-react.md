# Exec Plan: Upgrade Answering to Jido AI ReAct Agent with Tools

**Date**: 2026-04-22
**Author**: Jad
**Status**: `completed`
**Related debt**: confidence_score is always `nil` (logged in tech-debt-tracker post ReqLLM migration)
**PR(s)**: TBD

---

## Goal

Transform `Zaq.Agent.Answering` from a single-shot `ReqLLM.Generation.generate_text/3` call
into a proper Jido AI agent that uses the ReAct (Reason → Act → Observe) strategy.

The agent gains two tools: **SearchKnowledgeBase** (refine the context when chunks are
insufficient) and **AskForClarification** (signal ambiguity instead of hallucinating).

Done looks like:
- `Answering.ask/2` public interface is **unchanged** — callers see no difference.
- Poor-context questions trigger an extra search pass and produce a better answer.
- Ambiguous questions return a structured clarification request that the pipeline
  surfaces to the user instead of a low-confidence guess.
- `mix precommit` passes; all existing tests stay green; new tests cover the tools
  and the new code paths.

---

## Context

Files read before writing this plan:

- [x] `docs/services/agent.md`
- [x] `lib/zaq/agent/answering.ex` — current single-shot implementation
- [x] `lib/zaq/agent/retrieval.ex` — shows hybrid search entry point via NodeRouter
- [x] `lib/zaq/agent/factory.ex` — existing `use Jido.AI.Agent` pattern
- [x] `lib/zaq/agent/tools/registry.ex` — whitelisted tool registry
- [x] `lib/zaq/agent/pipeline.ex` — pipeline that calls `Answering.ask/2`
- [x] `lib/zaq/ingestion/document_processor.ex` — `query_extraction/2` and `apply_permission_filter/4`
- [x] `docs/exec-plans/active/2026-04-22-langchain-to-jido-ai-migration.md` — COMPLETE; ReqLLM in place

---

## Approach

### Why ReAct for Answering?

The current answering path is a single LLM call with a fixed system prompt that
embeds the retrieved chunks. Two classes of failure cannot be fixed without loops:

1. **Insufficient context**: Retrieval returned tangentially-related chunks. A single
   call hallucinates or gives a vague "I don't know" answer. With ReAct, the agent
   can issue a `search_knowledge_base` call with a refined query and try again.

2. **Ambiguous question**: The user's question has multiple valid interpretations.
   Instead of picking one silently, the agent should use `ask_for_clarification` to
   return a structured prompt that the pipeline surfaces back to the user.

### Architecture

```
Answering.ask/2          (unchanged public interface)
  └─ starts transient Jido.AgentServer (via Task or direct GenServer.start)
       └─ AnsweringAgent  (use Jido.AI.Agent, ReAct strategy)
            ├─ Tool: SearchKnowledgeBase  → calls ingestion hybrid search
            └─ Tool: AskForClarification → returns structured clarification map
  └─ collects result, normalises to %Answering.Result{}
  └─ stops transient server
```

**Key constraints:**
- `Answering.ask/2` stays stateless from the pipeline's perspective.
- The transient server is started, used, and stopped within a single `ask/2` call.
- `SearchKnowledgeBase` calls ingestion via `NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, ...)` — same pattern as `Pipeline.do_query_extraction/2`, not a direct module call.
- `SearchKnowledgeBase` MUST explicitly pass `person_id` and `team_ids`. **If `person_id` is `nil`, the tool returns `{:error, :permission_context_missing}` rather than silently bypassing the filter** (the filter's clause 2 at `document_processor.ex:1074` passes `person_id: nil` through without filtering — a silent bypass we must not trigger from this tool).
- `AskForClarification` is a pure in-process action (no LLM call needed).
- `Pipeline.run/2` is extended to detect `clarification_needed: true` in the result
  and return a user-facing clarification prompt.

### Why not use the existing Factory?

`Factory` is designed for long-lived BO-configured agent servers where the system
prompt and tools are set once and reused across many requests. The answering agent
gets a fresh system prompt (with embedded context chunks) for every request — a
persistent server would need its prompt reset every call, adding race-condition risk.
A transient server is the clean fit.

---

## Steps

### Phase 1 — SearchKnowledgeBase tool (½ day)

**New file**: `lib/zaq/agent/tools/search_knowledge_base.ex`

```elixir
defmodule Zaq.Agent.Tools.SearchKnowledgeBase do
  use Jido.Action,
    name: "search_knowledge_base",
    description: """
    Search the ZAQ knowledge base for relevant information.
    Use this when the context provided in the system prompt is insufficient
    to answer the question with confidence.
    """,
    schema: [
      query: [type: :string, required: true,
              doc: "The refined search query to look up"]
    ]

  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  # node_router and document_processor injected via context for testability.
  def run(%{query: query}, context) do
    person_id       = Map.get(context, :person_id)
    team_ids        = Map.get(context, :team_ids, [])
    node_router_mod = Map.get(context, :node_router, NodeRouter)
    doc_proc_mod    = Map.get(context, :document_processor, DocumentProcessor)

    # Fail explicitly rather than silently bypassing the permission filter.
    # DocumentProcessor.apply_permission_filter/4 clause 2 (document_processor.ex:1074)
    # passes person_id: nil through without any filtering — never trigger that here.
    if is_nil(person_id) do
      {:error, :permission_context_missing}
    else
      opts = [person_id: person_id, team_ids: team_ids, skip_permissions: false]

      case node_router_mod.call(:ingestion, doc_proc_mod, :query_extraction, [query, opts]) do
        {:ok, chunks} ->
          formatted = Enum.map_join(chunks, "\n\n", &format_chunk/1)
          {:ok, %{chunks: formatted, count: length(chunks)}}

        {:error, reason} ->
          {:error, "Knowledge base search failed: #{inspect(reason)}"}
      end
    end
  end

  defp format_chunk(%{"content" => content, "source" => source}),
    do: "Source: #{source}\n#{content}"

  defp format_chunk(%{"content" => content}), do: content
end
```

**Key permission notes:**
- Always passes `skip_permissions: false` — this is a user-facing tool, never admin.
- `person_id: nil` → explicit `{:error, :permission_context_missing}` rather than
  hitting the silent-bypass clause in `apply_permission_filter/4` at line 1074.
- `node_router` and `document_processor` injected via the Jido action `context` map
  for testability — mirrors how `Pipeline` accepts injectable opts.
- Uses `NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, ...)` —
  the same call pattern as `Pipeline.do_query_extraction/2`. No direct module calls.

**Update `Tools.Registry`**: add `"answering.search_knowledge_base"`,
`"answering.get_source_content"`, and `"answering.ask_for_clarification"` entries
(answering-only tools, prefixed so they are not BO-configurable by default).

---

### Phase 2 — GetSourceContent tool (½ day)

Retrieval returns truncated chunks. When the agent identifies a relevant source path
from the initial context (e.g. `"Source: /docs/hr-policy.pdf"`), this tool fetches
all chunks for that document in order, concatenated — giving the agent complete
context before committing to a citation.

**New function in `DocumentProcessor`** (no existing function does permission-gated
full-document fetch):

```elixir
@doc """
Fetches all chunks for a document identified by its source path, concatenated
in chunk_index order, with permission enforcement.

## Options
  * `:person_id`  — required; returns `{:error, :permission_context_missing}` if nil
  * `:team_ids`   — list of team IDs (default `[]`)
  * `:skip_permissions` — always false from external callers; kept for signature parity
"""
@spec get_source_content(String.t(), keyword()) ::
        {:ok, %{content: String.t(), source: String.t(), chunk_count: non_neg_integer()}}
        | {:error, :permission_context_missing | :not_found | :access_denied}
def get_source_content(source, opts \\ []) do
  person_id = Keyword.get(opts, :person_id)
  team_ids  = Keyword.get(opts, :team_ids, [])

  if is_nil(person_id) do
    {:error, :permission_context_missing}
  else
    case Document.get_by_source(source) do
      nil ->
        {:error, :not_found}

      %Document{id: doc_id} ->
        permitted = Zaq.Ingestion.list_permitted_document_ids(person_id, team_ids, [doc_id])

        if doc_id in permitted do
          chunks = Chunk.list_by_document(doc_id)
          content = chunks |> Enum.map_join("\n\n", & &1.content)
          {:ok, %{content: content, source: source, chunk_count: length(chunks)}}
        else
          {:error, :access_denied}
        end
    end
  end
end
```

**New file**: `lib/zaq/agent/tools/get_source_content.ex`

```elixir
defmodule Zaq.Agent.Tools.GetSourceContent do
  use Jido.Action,
    name: "get_source_content",
    description: """
    Fetches the full content of a specific source document by its path.
    Use this when the initial retrieved chunks mention a source that seems
    highly relevant but you only have a partial excerpt. The source path
    must come from a [[source:path]] marker already present in the context —
    do not guess paths.
    """,
    schema: [
      source: [type: :string, required: true,
               doc: "The source path exactly as it appears in the retrieved context"]
    ]

  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  def run(%{source: source}, context) do
    person_id       = Map.get(context, :person_id)
    team_ids        = Map.get(context, :team_ids, [])
    node_router_mod = Map.get(context, :node_router, NodeRouter)
    doc_proc_mod    = Map.get(context, :document_processor, DocumentProcessor)

    if is_nil(person_id) do
      {:error, :permission_context_missing}
    else
      opts = [person_id: person_id, team_ids: team_ids]

      case node_router_mod.call(:ingestion, doc_proc_mod, :get_source_content, [source, opts]) do
        {:ok, %{content: content, chunk_count: count}} ->
          {:ok, %{content: content, source: source, chunk_count: count}}

        {:error, :access_denied} ->
          {:error, "Access denied to source: #{source}"}

        {:error, :not_found} ->
          {:error, "Source not found: #{source}"}

        {:error, reason} ->
          {:error, "Failed to fetch source content: #{inspect(reason)}"}
      end
    end
  end
end
```

**Key permission notes:**
- Same `person_id: nil` guard as `SearchKnowledgeBase`.
- Permission is checked via `list_permitted_document_ids/3` with `[doc_id]` — a single-item check.
- `access_denied` is a clean error, not a silent omission.
- The system prompt instructs the agent to only pass source paths that already appear in the retrieved context — prevents path-guessing / traversal.

---

### Phase 4 — AskForClarification tool (< ½ day)

**New file**: `lib/zaq/agent/tools/ask_for_clarification.ex`

```elixir
defmodule Zaq.Agent.Tools.AskForClarification do
  use Jido.Action,
    name: "ask_for_clarification",
    description: """
    Use this tool when the user's question is ambiguous or could have multiple
    valid interpretations and a clarifying question would lead to a better answer.
    Do NOT use this as a substitute for searching when context is simply missing.
    """,
    schema: [
      reason:      [type: :string, required: true,
                    doc: "Why clarification is needed"],
      question:    [type: :string, required: true,
                    doc: "The clarifying question to ask the user"]
    ]

  def run(%{reason: reason, question: question}, _context) do
    {:ok, %{clarification_needed: true, reason: reason, question: question}}
  end
end
```

---

### Phase 5 — AnsweringAgent module (1 day)

**New file**: `lib/zaq/agent/answering_agent.ex`

```elixir
defmodule Zaq.Agent.AnsweringAgent do
  @moduledoc """
  Jido AI agent for response formulation using the ReAct strategy.

  Receives retrieved context embedded in the system prompt plus the user
  question. May issue additional knowledge-base searches before committing
  to an answer, and may request clarification when the question is ambiguous.

  Used internally by `Zaq.Agent.Answering.ask/2` as a transient per-request
  process. Do not start this agent as a long-lived server.
  """

  use Jido.AI.Agent,
    name: "answering_agent",
    description: "Formulates answers from retrieved ZAQ knowledge base context",
    request_policy: :reject,
    tools: [
      Zaq.Agent.Tools.SearchKnowledgeBase,
      Zaq.Agent.Tools.GetSourceContent,
      Zaq.Agent.Tools.AskForClarification
    ]
end
```

The system prompt (injected per-request) instructs the agent:

```
You are a knowledge base assistant. Retrieved context is provided above.

ReAct rules:
1. Reason: Do the retrieved chunks contain enough information to answer directly?
2. If chunks are insufficient — call `search_knowledge_base` with a refined query
   (max 2 attempts).
3. If a source looks highly relevant but you only have a partial excerpt — call
   `get_source_content` with that exact source path to fetch the full document
   (only use paths already present in the context, never guess).
4. If the question is genuinely ambiguous — call `ask_for_clarification`.
5. When you have enough context — answer and cite using [[source:path]] markers.
6. Never fabricate facts not present in the retrieved context.
```

This prompt is prepended as an instruction block in `Answering.ask/2` before the
existing system_prompt (which embeds the retrieved chunks).

---

### Phase 6 — Wire into `Answering.ask/2` (½ day)

Replace the `ReqLLM.Generation.generate_text/3` call block with:

```elixir
# Start transient agent
{:ok, server} = Jido.AgentServer.start_link(
  agent: AnsweringAgent,
  id: "answering_#{System.unique_integer([:positive])}"
)
:ok = Jido.AI.set_system_prompt(server, full_system_prompt)

ask_opts = [
  tools: [SearchKnowledgeBase, GetSourceContent, AskForClarification],
  llm_opts: LLM.generation_opts(),
  context: %{person_id: person_id, team_ids: team_ids},
  timeout: 60_000
]

result =
  try do
    AnsweringAgent.ask(server, question, ask_opts)
  after
    Jido.AgentServer.stop(server)
  end
```

Parse the result:
- If the agent used `AskForClarification`, the final message will contain
  `clarification_needed: true` — surface this in the `Result` struct via a new
  optional field `:clarification` (binary question string or `nil`).
- Otherwise parse the answer text as before into `%Result{}`.

**`%Answering.Result{}` change**: add `clarification: String.t() | nil` field
(defaults to `nil` — fully backward-compatible).

---

### Phase 7 — Handle clarification in Pipeline (½ day)

In `Pipeline.do_run/2`, after `answering.ask/2` returns:

```elixir
case answering_mod.ask(system_prompt, ask_opts) do
  {:ok, %Result{clarification: question}} when is_binary(question) ->
    %{answer: question, clarification_needed: true, ...zero tokens...}

  {:ok, %Result{} = result} ->
    # existing path
    ...

  {:error, _} ->
    # existing path
    ...
end
```

Callers (BO chat, Mattermost, Slack adapters) already handle the `answer` field —
the clarification question is delivered as the answer text, and `clarification_needed: true`
lets channel adapters style it differently (e.g. a prompt bubble vs a regular reply).

---

### Phase 8 — Tests (1 day)

- [ ] `test/zaq/agent/tools/search_knowledge_base_test.exs`
  - Happy path: returns formatted chunks
  - `person_id: nil` → `{:error, :permission_context_missing}`
  - NodeRouter error: propagates `{:error, ...}`

- [ ] `test/zaq/agent/tools/get_source_content_test.exs`
  - Happy path: full document returned as concatenated chunks
  - `person_id: nil` → `{:error, :permission_context_missing}`
  - Document not found → `{:error, "Source not found: ..."}`
  - Permission denied → `{:error, "Access denied to source: ..."}`

- [ ] `test/zaq/agent/tools/ask_for_clarification_test.exs`
  - Returns `{:ok, %{clarification_needed: true, ...}}`

- [ ] `test/zaq/ingestion/document_processor_test.exs`
  - Add: `get_source_content/2` — permitted, not_found, access_denied, nil person_id

- [ ] `test/zaq/agent/answering_agent_test.exs`
  - Sufficient context → direct answer, no tool calls
  - Insufficient context → `SearchKnowledgeBase` called, richer answer
  - Partial excerpt → `GetSourceContent` called, full document used
  - Ambiguous question → `AskForClarification` called, result has `clarification:`

- [ ] `test/zaq/agent/answering_test.exs` — existing tests must stay green
  - Add: `ask/2` with clarification result surfaces `:clarification` field

- [ ] `test/zaq/agent/pipeline_test.exs`
  - Answering returns clarification → pipeline returns it as `answer`, sets
    `clarification_needed: true`

---

### Phase 9 — Update docs (½ day)

- [ ] `docs/services/agent.md` — update Answering section, add all three tool
  descriptions, add `AnsweringAgent` and `DocumentProcessor.get_source_content/2`
  to Files/Modules lists
- [ ] `docs/QUALITY_SCORE.md` — re-grade Agent domain (ReAct + tools = quality gain)

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Transient server per `ask/2` call | Answering gets a fresh system prompt with context chunks per request; persistent server would need prompt reset every call, adding race risk | 2026-04-22 |
| `SearchKnowledgeBase` uses `NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, ...)` | Mirrors `Pipeline.do_query_extraction/2` pattern exactly; agent node must not call ingestion modules directly | 2026-04-22 |
| Both `SearchKnowledgeBase` and `GetSourceContent` error on `person_id: nil` | `apply_permission_filter/4` clause 2 (dp.ex:1074) silently bypasses all filtering when `person_id` is nil — this would leak cross-tenant chunks; explicit error is safer | 2026-04-22 |
| `GetSourceContent` requires source path to already be in context | Prevents path traversal; the system prompt explicitly says "only use paths already present in the retrieved context" | 2026-04-22 |
| `DocumentProcessor.get_source_content/2` is a new function (no existing equivalent) | `query_extraction` does vector search; `Chunk.list_by_document` + `Ingestion.get_document_by_source!` give the right primitives but need to be wrapped with permission check in one call | 2026-04-22 |
| `AskForClarification` is a pure action (no LLM call) | Clarification is a deterministic signal — no inference needed to return a user question | 2026-04-22 |
| Add `clarification` field to `%Result{}` (default `nil`) | Backward-compatible; all existing callers pattern-match on `:answer` and are unaffected | 2026-04-22 |
| Tools prefixed `answering.*` in Registry | These tools are not suitable for BO-configurable agents (they carry pipeline-level concerns); the prefix communicates that | 2026-04-22 |
| Max 2 search attempts baked into system prompt | Prevents runaway tool loops; ReqLLM does not expose a max_steps config so the constraint lives in the prompt | 2026-04-22 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Verify `Jido.AgentServer.start_link` accepts `id:` as unique name to avoid collisions | Jad | open |
| Confirm `Jido.AI.set_system_prompt/2` returns synchronously before `ask/3` is called | Jad | open |
| Confirm `NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, ...)` call shape — already used in `Pipeline.do_query_extraction/2` but verify on agent node | Jad | resolved — mirrored from pipeline |

---

## Definition of Done

- [ ] `Zaq.Agent.Tools.SearchKnowledgeBase` implemented and registered
- [ ] `Zaq.Agent.Tools.GetSourceContent` implemented and registered
- [ ] `DocumentProcessor.get_source_content/2` added with permission guard
- [ ] `Zaq.Agent.Tools.AskForClarification` implemented and registered
- [ ] `Zaq.Agent.AnsweringAgent` created with all three tools
- [ ] `Answering.ask/2` delegates to the transient agent; public interface unchanged
- [ ] `%Answering.Result{}` has `clarification` field (nil-default)
- [ ] Pipeline surfaces clarification as answer text + `clarification_needed: true`
- [ ] All new tests written and passing (`mix test test/zaq/agent/`)
- [ ] Existing `answering_test.exs` tests still green
- [ ] `mix precommit` passes
- [ ] `docs/services/agent.md` updated
- [ ] Plan moved to `docs/exec-plans/completed/`
