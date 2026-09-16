# Agent Tools

This is the authoritative tool-routing and memory policy for all coding agents. Before tool use, read the boundary and routing sections; consult the reference and maintenance sections only as needed. Host tool requirements take precedence. Context Mode uses native `ctx_*` commands/tools, not an MCP server.

## Tool boundaries

Choose by task, not global ranking:

- **Serena is code intelligence (semantic compression):** IDE/LSP operations select the code symbols and relationships needed, avoiding whole-file reads.
- **Context Mode is context control (contextual compression):** sandbox processing, indexing and retrieval select relevant operational observations without flooding context.
- **The agent reasons and plans**; neither tool replaces that responsibility.

| Need | Mechanism |
| --- | --- |
| Definitions, callers, references, implementations, code relationships | Serena overview → targeted definitions/references/implementations |
| Supported symbol edits/refactors | Serena symbol-aware tools, subject to host-required patch/edit tools |
| Logs, test/build output, large diffs, JSON/API data, large documentation | Context Mode processing; index if later retrieval is useful |
| Indexed knowledge and session recall | `ctx_search`; verify live repository state before acting |
| Small known text/configuration section or exact edit text | Targeted direct read |
| New files, Markdown/configuration, non-symbolic edits | Available patch/edit tool |
| Short fixed observations or Git mutations | Direct shell; large/unpredictable output goes through Context Mode |

Read Serena's initial instructions before using it. Use exposed tool names, not assumed host-specific prefixes. Retrieve bodies only when needed, bounding queries by file, symbol or result size.

Normal code loop: **overview → targeted definitions/references → hypothesis → targeted edit → Context Mode test execution → concise findings**. Do not index the entire source tree merely to locate a symbol or replace live semantic navigation with `ctx_search`. Aggregate source analysis (counts, statistics, broad textual audits) does belong in Context Mode.

If Serena, language support or a semantic operation is unavailable, report it and use another available LSP tool or bounded text searches/targeted reads. Process large fallback results in Context Mode. Never claim an unavailable tool was used.

Call Serena directly for bounded semantic queries. Do not assume Context Mode can invoke, intercept or wrap every Serena/MCP tool or browser result. Narrow responses at the producer; process/index exported results only when the integration makes them available. Never dump large results into context just to index them afterward.

## Mandatory routing

These rules apply to operational/textual analysis, not as a replacement for semantic navigation above.

- **Think in code:** filter, count, parse, compare and aggregate data in `ctx_execute`/`ctx_execute_file`; print only findings. Use robust JavaScript with Node.js built-ins, `try/catch`, null handling and Node/Bun compatibility; no npm dependencies.
- **Shell output:** route large, unpredictable or analysis-bound output through `ctx_execute` or `ctx_batch_execute`. Command names are not exemptions: large Git diffs, install logs, builds and tests stay out of raw context. Direct shell is for short fixed observations and mutations.
- **Reads/searches:** use Serena for source relationships; targeted reads for edit text or small known docs/configuration; sandbox large documents, structured data and broad textual searches. Scope searches by file/directory.
- **Web:** shell `curl`/`wget`, inline HTTP requests and direct URL-fetch tools are blocked. Do not retry blocked routes. Use `ctx_fetch_and_index` then `ctx_search`, or HTTP calls inside `ctx_execute` (e.g. JavaScript `fetch`).
- **Batching:** issue independent related operations together. Use batch concurrency for independent I/O only; sequence dependencies and shared-state work safely.
- **Output:** use descriptive source labels for retrieval. Summarize findings, not raw logs. Follow `AGENTS.md` response limits.

## Memory and delegation

- Repository documentation owns standards; Beadwork owns durable plans, tasks and progress. GitHub remains overall project management.
- Serena memories hold stable project knowledge (architecture, conventions, modules, commands), consistent with repository documentation.
- Context Mode supports session/working recall (edits, errors, decisions, command results). Automatic capture depends on the installed integration; verify it, never promise complete history.
- After compaction, retrieve relevant context and verify against current files, Git and Beadwork. Unchanged policies already in context need not be reread. Neither memory store replaces the authoritative sources.
- Delegated prompts must require applicable policies when not inherited. Do not assume automatic injection, agent-type upgrades or tool access; report missing capabilities and use bounded fallbacks.

## Native tool reference

Use this catalog after choosing Context Mode, not ahead of Serena for code navigation.

| Tool | Use |
| --- | --- |
| `ctx_batch_execute` | Gather operational commands and query indexed output in one call; label commands descriptively. `concurrency: 1–8` for independent I/O; `1` for stateful work. |
| `ctx_execute` | Process data/run code in 12 supported languages (installed runtimes vary); print only needed observations. |
| `ctx_execute_file` | Analyze a file in sandbox; raw content stays out of context. |
| `ctx_index` | Chunk markdown into FTS5 for BM25 retrieval when needed later. |
| `ctx_search` | Batch related questions about indexed content/session recall into one call. |
| `ctx_fetch_and_index` | Fetch, chunk, index URLs. Default TTL 24 hours; `ttl` in milliseconds; `ttl: 0` or `force: true` bypasses cache. Batch `requests: [{url, source}, ...]` with `concurrency: 1–8`. |
| `ctx_stats` | Context savings, tool call counts, session statistics. |
| `ctx_doctor` | Installation diagnostics: runtimes, hooks, FTS5, versions. |
| `ctx_upgrade` | Upgrade from GitHub, rebuild/reconfigure; follow returned instructions. |
| `ctx_purge` | Irreversible deletion of explicitly scoped indexed session/project content; warn first. |

## Maintenance commands

| User command | Required behavior |
| --- | --- |
| `ctx stats` | Call `ctx_stats`; display full output verbatim. |
| `ctx doctor` | Call `ctx_doctor`; display diagnostics as a checklist. Do not assume a shell command is returned. |
| `ctx upgrade` | Call `ctx_upgrade`; follow returned instructions including required shell commands. Show results as a checklist; tell the user to restart the session. |
| `ctx purge` | Ask for explicit session/project scope if unspecified. Warn before irreversible deletion; call `ctx_purge` with `confirm: true` and exactly one scope (`sessionId` or `scope: "project"`). |

Knowledge base and session stats survive `/clear` or `/compact`; use scoped purge only when requested, not automatically during recovery.
