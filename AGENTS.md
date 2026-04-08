# ZAQ Agent Entry Point

You are an autonomous coding agent working on the ZAQ codebase — an AI-powered company brain built with Elixir/Phoenix.

This file is your **map**. Read the relevant doc before starting any task.

---

## 📚 Documentation Map

### Core Docs
| What you need | Where to look |
|---|---|
| Project overview, tech stack, project structure | `docs/project.md` |
| Architecture, multi-node roles, NodeRouter | `docs/architecture.md` |
| Naming conventions, module & API design | `docs/conventions.md` |
| Git workflow, branching, semantic versioning | `docs/workflows.md` |
| Code quality standards, debt prevention | `docs/code-quality.md` |
| Dev setup, tool usage, sub-agents | `docs/dev-setup.md` |
| Elixir, Mix, Ecto, Test guidelines | `docs/elixir.md` |
| Phoenix, LiveView, HTML, JS/CSS, UI/UX | `docs/phoenix.md` |

### Planning & Quality
| What you need | Where to look |
|---|---|
| Agent workflow (plan → implement → PR) | `docs/WORKFLOW_AGENT.md` |
| Execution plan template | `docs/exec-plans/PLAN_TEMPLATE.md` |
| Quality grades per domain | `docs/QUALITY_SCORE.md` |
| Harness improvement roadmap | `docs/harness-roadmap.md` |
| Active execution plans | `docs/exec-plans/active/` |
| Completed plans & decision logs | `docs/exec-plans/completed/` |
| Known technical debt | `docs/exec-plans/tech-debt-tracker.md` |

### Service Deep-Dives
| Service | Where to look |
|---|---|
| Agent pipeline, LLM, retrieval, answering | `docs/services/agent.md` |
| BO authentication & authorization | `docs/services/bo-auth.md` |
| Channels, adapters, Mattermost | `docs/services/channels.md` |
| Engine, conversations, notifications, dispatch | `docs/services/engine.md` |
| Ingestion pipeline, chunking, embedding | `docs/services/ingestion.md` |
| License loading & feature gating | `docs/services/license.md` |
| System config, secrets, encryption | `docs/services/system-config.md` |
| Telemetry, metrics, buffer behavior | `docs/services/telemetry.md` |

---

## ⚡ Core Rules (Always Apply)

- **Follow `docs/WORKFLOW_AGENT.md`** on every task — orient, plan, implement, validate, PR, close out.
- **Read the relevant doc first** before starting any task.
- **Never push directly to `main`** — all changes go through a PR.
- **Run `mix precommit`** before every commit. Never replace it with ad-hoc checks.
- **All cross-service BO calls go through `NodeRouter.call/4`** — never direct module calls.
- **Check `docs/exec-plans/active/`** before starting any complex or multi-step task.
- **All related operations must be concurrent in a single message** — never split related reads/writes across messages.
- When a task touches keys, tokens, passwords, or encrypted config fields — read `docs/services/system-config.md` first.

---

## 🛠 Tool Priority

1. `mcp__plugin_context-mode_context-mode__*` — file reads, searches, code execution
2. `mcp__serena__*` — symbol navigation, file creation, replacing symbol bodies
3. `ctx_execute` over raw Bash for shell commands

---

## 🤖 Sub-Agents

Located in `.claude/agents/`. Shared memory at `.swarm/memory.json`.

### Use the right agent for the task

| Task | Use agent |
|---|---|
| Break down a complex task, write an exec plan | `project-planner` or `planner` |
| Build a new context API or domain module | `api-developer` |
| Write tests before implementing | `tdd-specialist` or `tdd` |
| Review a PR for quality and conventions | `code-reviewer` or `reviewer` |
| Reproduce and fix a bug | `debugger` |
| Clean up or restructure existing code | `refactor` |
| **Audit existing docs for drift against real code** | `doc-gardening` ← not `doc-writer` |
| Write new documentation from scratch | `doc-writer` |
| Audit for security vulnerabilities | `security-scanner` |
| CI, deployment, infrastructure changes | `devops-engineer` |
| Translate requirements into specs | `product-manager` |
| Run test suites and report results | `test-runner` |
| Detect direct module calls bypassing NodeRouter | `node-router-enforcer` |
| Detect unencrypted secret fields in schemas | `secret-field-auditor` |

### All agents
`project-planner` · `planner` · `api-developer` · `tdd-specialist` · `tdd` · `code-reviewer` · `reviewer` · `debugger` · `refactor` · `doc-gardening` · `doc-writer` · `security-scanner` · `devops-engineer` · `product-manager` · `test-runner` · `node-router-enforcer` · `secret-field-auditor`