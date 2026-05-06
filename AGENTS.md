# ZAQ Agent Entry Point

You are an autonomous coding agent working on the ZAQ codebase — an AI-powered company brain built with Elixir/Phoenix.

This file is your **map**. Read the relevant doc before starting any task.

---

## 📚 Documentation Map

### Core Docs

| What you need                                   | Where to look           |
| ----------------------------------------------- | ----------------------- |
| Project overview, tech stack, project structure | `docs/project.md`       |
| Architecture, multi-node roles, NodeRouter      | `docs/architecture.md`  |
| Naming conventions, module & API design         | `docs/conventions.md`   |
| Git workflow, branching, semantic versioning    | `docs/workflows.md`     |
| Code quality standards, debt prevention         | `docs/code-quality.md`  |
| Dev setup, tool usage, sub-agents               | `docs/dev-setup.md`     |
| Elixir, Mix, Ecto, Test guidelines              | `docs/elixir.md`        |
| Phoenix, LiveView, HTML, JS/CSS, UI/UX          | `docs/phoenix.md`       |
| BO layout, design tokens, colors, components    | `docs/bo-components.md` |

### Planning & Quality

| What you need                          | Where to look                          |
| -------------------------------------- | -------------------------------------- |
| Agent workflow (plan → implement → PR) | `docs/WORKFLOW_AGENT.md`               |
| Execution plan strategy (mandatory)    | `docs/exec-plans/PLAN_STRATEGY.md`     |
| Quality grades per domain              | `docs/QUALITY_SCORE.md`                |
| Harness improvement roadmap            | `docs/harness-roadmap.md`              |
| Active execution plans                 | `docs/exec-plans/active/`              |
| Completed plans & decision logs        | `docs/exec-plans/completed/`           |
| Known technical debt                   | `docs/exec-plans/tech-debt-tracker.md` |

### Service Deep-Dives

| Service                                        | Where to look                    |
| ---------------------------------------------- | -------------------------------- |
| Agent pipeline, LLM, retrieval, answering      | `docs/services/agent.md`         |
| BO authentication & authorization              | `docs/services/bo-auth.md`       |
| Channels, adapters, Mattermost                 | `docs/services/channels.md`      |
| Engine, conversations, notifications, dispatch | `docs/services/engine.md`        |
| Ingestion pipeline, chunking, embedding        | `docs/services/ingestion.md`     |
| License loading & feature gating               | `docs/services/license.md`       |
| System config, secrets, encryption             | `docs/services/system-config.md` |
| Telemetry, metrics, buffer behavior            | `docs/services/telemetry.md`     |

---

## ⚡ Core Rules (Always Apply)

- **Follow `docs/WORKFLOW_AGENT.md`** on every task — orient, plan, implement, validate, PR, close out.
- **Read the relevant doc first** before starting any task.
- **Use `docs/exec-plans/PLAN_STRATEGY.md` for every new execution plan** and start from `docs/exec-plans/PLAN_TEMPLATE.md`.
- **Never push directly to `main`** — all changes go through a PR.
- **Run `mix precommit`** before every commit. Never replace it with ad-hoc checks.
- **Target at least 90% test coverage for new development** (unit/integration as appropriate). If an exception is needed, document the rationale and follow-up plan in the PR.
- **All cross-service BO calls go through `NodeRouter.call/4`** — never direct module calls.
- **Before adding a function to any module, read its `@moduledoc`** — confirm the function fits the module's stated responsibility. If it doesn't belong, find the correct module first.
- **Check `docs/exec-plans/active/`** before starting any complex or multi-step task.
- **All related operations must be concurrent in a single message** — never split related reads/writes across messages.
- When a task touches keys, tokens, passwords, or encrypted config fields — read `docs/services/system-config.md` first.

### Agent Service Rules (apply when touching `lib/zaq/agent/`)

- **Use existing infrastructure before building new paths** — before implementing any LLM call, agent lifecycle, or response builder, confirm whether `Factory`, `Executor`, `Outgoing`, or `History` already covers the case. If it does, use or extend it. Never create a parallel path. See `docs/services/agent.md` for the Entry Point Decision Tree.
- **Provider/URL logic has one home** — all provider-atom normalisation, fixed-URL detection, and base-URL injection live in `Zaq.Agent.ProviderSpec`. Credential resolution lives in `get_ai_provider_credential/1`. Model spec assembly (calling both) lives in `Zaq.Agent.Factory`. All other modules (`ServerManager`, `Pipeline`, `Answering`, etc.) receive pre-built model spec objects and must never construct or inspect provider URLs or credentials directly.
- **The default answering agent is not a special case** — it is a configured agent with default values. `ServerManager` must not branch on agent type. Any logic that applies only to "the answering agent" is a smell: either it belongs to all agents (move it to the general path) or it should not exist.
- **`nil` person_id is never an implicit permission grant** — if a function receives `person_id: nil` with no explicit `skip_permissions: true` in context, it must return only public data. Explicit admin access must be opt-in. Never derive permissions from nil. See `docs/services/agent.md` security note.
- **`ServerManager` state must be minimal** — if a state variable exists only to trigger future behavior, use `Process.send_after/3` instead. Ask: "would this variable still be needed if I used a timer?" If no, use the timer.
- **Provider enumerations must come from `llm_db`, not source code** — provider names, endpoint configs, and capability flags that exist in `llm_db` must be read at runtime. Hardcoded provider lists (`@reqllm_providers`, `@fixed_url_providers`, etc.) create silent bugs where adding a provider in the admin UI has no effect until a developer also edits source.

---

## 🛠 Tool Priority

1. `mcp__plugin_context-mode_context-mode__*` — file reads, searches, code execution
2. `mcp__serena__*` — symbol navigation, file creation, replacing symbol bodies
3. `ctx_execute` over raw Bash for shell commands

# context-mode — MANDATORY routing rules

You have context-mode MCP tools available. These rules are NOT optional — they protect your context window from flooding. A single unrouted command can dump 56 KB into context and waste the entire session.

## Think in Code — MANDATORY

When you need to analyze, count, filter, compare, search, parse, transform, or process data: **write code** that does the work via `context-mode_ctx_execute(language, code)` and `console.log()` only the answer. Do NOT read raw data into context to process mentally. Your role is to PROGRAM the analysis, not to COMPUTE it. Write robust, pure JavaScript — no npm dependencies, only Node.js built-ins (`fs`, `path`, `child_process`). Always use `try/catch`, handle `null`/`undefined`, and ensure compatibility with both Node.js and Bun. One script replaces ten tool calls and saves 100x context.

## BLOCKED commands — do NOT attempt these

### curl / wget — BLOCKED

Any shell command containing `curl` or `wget` will be intercepted and blocked by the context-mode plugin. Do NOT retry.
Instead use:

- `context-mode_ctx_fetch_and_index(url, source)` to fetch and index web pages
- `context-mode_ctx_execute(language: "javascript", code: "const r = await fetch(...)")` to run HTTP calls in sandbox

### Inline HTTP — BLOCKED

Any shell command containing `fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, or `http.request(` will be intercepted and blocked. Do NOT retry with shell.
Instead use:

- `context-mode_ctx_execute(language, code)` to run HTTP calls in sandbox — only stdout enters context

### Direct web fetching — BLOCKED

Do NOT use any direct URL fetching tool. Use the sandbox equivalent.
Instead use:

- `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)` to query the indexed content

## REDIRECTED tools — use sandbox equivalents

### Shell (>20 lines output)

Shell is ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`, and other short-output commands.
For everything else, use:

- `context-mode_ctx_batch_execute(commands, queries)` — run multiple commands + search in ONE call
- `context-mode_ctx_execute(language: "shell", code: "...")` — run in sandbox, only stdout enters context

### File reading (for analysis)

If you are reading a file to **edit** it → reading is correct (edit needs content in context).
If you are reading to **analyze, explore, or summarize** → use `context-mode_ctx_execute_file(path, language, code)` instead. Only your printed summary enters context.

### grep / search (large results)

Search results can flood context. Use `context-mode_ctx_execute(language: "shell", code: "grep ...")` to run searches in sandbox. Only your printed summary enters context.

## Tool selection hierarchy

1. **GATHER**: `context-mode_ctx_batch_execute(commands, queries)` — Primary tool. Runs all commands, auto-indexes output, returns search results. ONE call replaces 30+ individual calls. Each command: `{label: "descriptive header", command: "..."}`. Label becomes FTS5 chunk title — descriptive labels improve search.
2. **FOLLOW-UP**: `context-mode_ctx_search(queries: ["q1", "q2", ...])` — Query indexed content. Pass ALL questions as array in ONE call.
3. **PROCESSING**: `context-mode_ctx_execute(language, code)` | `context-mode_ctx_execute_file(path, language, code)` — Sandbox execution. Only stdout enters context.
4. **WEB**: `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)` — Fetch, chunk, index, query. Raw HTML never enters context.
5. **INDEX**: `context-mode_ctx_index(content, source)` — Store content in FTS5 knowledge base for later search.

## Output constraints

- Keep responses under 500 words.
- Write artifacts (code, configs, PRDs) to FILES — never return them as inline text. Return only: file path + 1-line description.
- When indexing content, use descriptive source labels so others can `search(source: "label")` later.

## ctx commands

| Command       | Action                                                                                |
| ------------- | ------------------------------------------------------------------------------------- |
| `ctx stats`   | Call the `stats` MCP tool and display the full output verbatim                        |
| `ctx doctor`  | Call the `doctor` MCP tool, run the returned shell command, display as checklist      |
| `ctx upgrade` | Call the `upgrade` MCP tool, run the returned shell command, display as checklist     |
| `ctx purge`   | Call the `purge` MCP tool with confirm: true. Warns before wiping the knowledge base. |

After /clear or /compact: knowledge base and session stats are preserved. Use `ctx purge` if you want to start fresh.

---

## 🤖 Sub-Agents

Located in `.claude/agents/`. Shared memory at `.swarm/memory.json`.

### Use the right agent for the task

| Task                                                | Use agent                          |
| --------------------------------------------------- | ---------------------------------- |
| Break down a complex task, write an exec plan       | `project-planner` or `planner`     |
| Build a new context API or domain module            | `api-developer`                    |
| Write tests before implementing                     | `tdd-specialist` or `tdd`          |
| Review a PR for quality and conventions             | `code-reviewer` or `reviewer`      |
| Reproduce and fix a bug                             | `debugger`                         |
| Clean up or restructure existing code               | `refactor`                         |
| **Audit existing docs for drift against real code** | `doc-gardening` ← not `doc-writer` |
| Write new documentation from scratch                | `doc-writer`                       |
| Audit for security vulnerabilities                  | `security-scanner`                 |
| CI, deployment, infrastructure changes              | `devops-engineer`                  |
| Translate requirements into specs                   | `product-manager`                  |
| Run test suites and report results                  | `test-runner`                      |
| Detect direct module calls bypassing NodeRouter     | `node-router-enforcer`             |
| Detect unencrypted secret fields in schemas         | `secret-field-auditor`             |

### All agents

`project-planner` · `planner` · `api-developer` · `tdd-specialist` · `tdd` · `code-reviewer` · `reviewer` · `debugger` · `refactor` · `doc-gardening` · `doc-writer` · `security-scanner` · `devops-engineer` · `product-manager` · `test-runner` · `node-router-enforcer` · `secret-field-auditor`
