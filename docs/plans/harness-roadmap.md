# Harness Improvement Roadmap

Current score: **84/100**
Target score: **96/100**

This document tracks what is left to build, why it matters, and how to implement it.
Each item is a self-contained implementation task that can be handed directly to Claude Code.

---

## ✅ Completed

| Task | Score gained |
|---|---|
| Documentation map & progressive disclosure | 18/20 |
| Quality & debt tracking (`QUALITY_SCORE.md`, `tech-debt-tracker.md`) | 14/20 |
| Planning system (`PLAN_TEMPLATE.md`, `WORKFLOW_AGENT.md`) | 12/20 |
| Context management (`AGENTS.md` lean TOC, `docs/` split) | 12/20 |
| E2E suite (Playwright + `ProcessorState`) | +2 |
| Persistent agent memory (`.swarm/memory.json`) | +2 |
| E2E observability endpoints (`/e2e/health`, `/e2e/telemetry/points`, `/e2e/logs/recent`) | +4 |

---

## Task 1 — Update `docs/services/` to Match Real Codebase

**Impact:** +4 points | **Effort:** Medium | **Priority:** High — do this first

### Why
Several modules exist in code but are undocumented. Agents working in those areas
have no context, which leads to incorrect implementations and architectural drift.
This is the highest-risk gap for day-to-day agent work right now.

### What's Missing

| Service doc | Missing from doc |
|---|---|
| `agent.md` | `pipeline.ex`, `llm_runner.ex`, `history.ex`, `citation_normalizer.ex`, `answering/result.ex` |
| `channels.md` | `dispatch_hook.ex`, `notification.ex`, `retrieval_channel.ex` moved to channels |
| `ingestion.md` | Full Python pipeline (`python/` directory), `sidecar.ex`, `delete_service.ex`, `rename_service.ex`, `directory_snapshot.ex`, `job_lifecycle.ex`, `source_path.ex` |
| `bo-auth.md` | `password_policy.ex`, `permissions.ex`, `user_notification_channel.ex`, forgot/reset password flow |
| Missing entirely | `docs/services/hooks.md` — full hooks system undocumented |
| Missing entirely | `docs/services/notifications.md` — engine notifications subsystem undocumented |

### How to Implement
1. Run `doc-gardening` agent first — catches obvious gaps automatically
2. For each service doc, read actual source files and update to reflect reality
3. Create `docs/services/hooks.md` from scratch
4. Create `docs/services/notifications.md` from scratch
5. Update `AGENTS.md` documentation map to include new service docs

### Hand to Claude Code
```
Read docs/services/agent.md and compare it against the actual files in lib/zaq/agent/.
Update the doc to reflect what is actually implemented. Then do the same for
docs/services/ingestion.md against lib/zaq/ingestion/. Then create
docs/services/hooks.md from lib/zaq/hooks/ and docs/services/notifications.md
from lib/zaq/engine/notifications/.
```

### Definition of Done
- Every module in `lib/zaq/` is referenced in at least one `docs/services/` file
- `hooks.md` and `notifications.md` exist and are linked from `AGENTS.md`
- `doc-gardening` agent finds no missing modules on next run

---

## Task 2 — Custom Linters for Architecture Enforcement

**Impact:** +6 points | **Effort:** High | **Priority:** High

### Why
The article is explicit: *"documentation alone doesn't keep a fully agent-generated
codebase coherent."* Layer rules and NodeRouter rules exist only as docs right now —
nothing stops an agent from violating them mechanically.

### What to Build

#### 2a — NodeRouter Linter
Flags any direct call to `Zaq.Agent.*`, `Zaq.Ingestion.*`, `Zaq.Engine.*`, or
`Zaq.Channels.*` from within `lib/zaq_web/`.

```
lib/zaq_web/live/bo/communication/chat_live.ex:42
  [C] Direct cross-service call detected. Use NodeRouter.call/4 instead.
  Zaq.Agent.Retrieval.ask(question, opts)
```

#### 2b — Layer Dependency Linter
Enforces `Types → Config → Repo → Service → Runtime → UI` dependency direction.
Flags any backwards dependency within a domain.

#### 2c — Secret Field Linter
Flags any new schema field whose name contains `key`, `token`, `password`, `secret`,
or `credential` that is not wrapped in `Zaq.Types.EncryptedString`.

#### 2d — Structured Logging Linter
Flags any `Logger.info/warn/error` call passing a plain string instead of a
structured keyword list.

### How to Implement
1. Read `mix credo` custom check docs: `mix help credo`
2. Create `lib/zaq/credo_checks/` directory
3. Implement each check as a module implementing `Credo.Check` behaviour
4. Add checks to `.credo.exs` under `checks: [custom: [...]]`
5. Wire into `mix precommit`
6. Write tests for each check in `test/zaq/credo_checks/`

### Hand to Claude Code
```
Read docs/architecture.md and docs/conventions.md, then implement the four custom
Credo checks described in docs/harness-roadmap.md Task 2. Create them in
lib/zaq/credo_checks/ and wire them into .credo.exs and mix precommit.
Write tests for each check.
```

### Definition of Done
- All four linters run as part of `mix precommit`
- Each linter has unit tests: violation detected + clean code passes
- Error messages include remediation instructions
- `mix credo --strict` passes on current codebase

---

## Task 3 — Run 3 Real Exec Plans

**Impact:** +4 points | **Effort:** Low | **Priority:** Medium

### Why
The exec plan system exists but has never been battle-tested. Real usage reveals
where the workflow breaks down and what needs to be tightened in `WORKFLOW_AGENT.md`.

### Recommended Tasks to Run

Pick three from `docs/exec-plans/tech-debt-tracker.md`:

| Task | Why it's a good test |
|---|---|
| Implement `forward_to_engine/1` in Mattermost adapter | Tests channels + engine + NodeRouter enforcement |
| Add role-based authorization plug | Tests accounts + auth + layer rules |
| Expose license status in BO | Tests license + LiveView + cross-service pattern |

### For Each Task
1. Create exec plan from `PLAN_TEMPLATE.md` in `docs/exec-plans/active/`
2. Hand to Claude Code: *"Read this plan and execute it step by step"*
3. Note where workflow breaks down or needs clarification
4. Update `WORKFLOW_AGENT.md` based on findings
5. Move completed plan to `docs/exec-plans/completed/`

### Definition of Done
- At least 3 tasks completed end-to-end using exec plan workflow
- `WORKFLOW_AGENT.md` updated based on real usage findings
- `docs/exec-plans/completed/` has at least 3 entries

---

## Task 4 — CI Doc Validation Jobs

**Impact:** +4 points | **Effort:** Medium | **Priority:** Medium

### Why
Nothing currently checks that file paths in `AGENTS.md` exist, that service docs
reference real modules, or that `QUALITY_SCORE.md` was updated after a domain changed.

### What to Build

#### 4a — Dead Link Checker
Mix task that reads all `docs/` files, extracts file paths and module references,
and verifies they exist in the repository.

```bash
mix zaq.docs.check
# docs/architecture.md:45 — referenced module does not exist: Zaq.Engine.Router
```

#### 4b — Cross-Link Validator
Verifies every file in `docs/services/` is referenced in `AGENTS.md`, and every
service directory in `lib/zaq/` has a corresponding `docs/services/` entry.

#### 4c — Quality Score Freshness Check
Verifies `docs/QUALITY_SCORE.md` "Last Updated" date is within 30 days.
Warns (non-blocking) if stale.

#### 4d — Tech Debt Tracker Sync
Verifies every `What's Left` section in `docs/services/` has a corresponding entry
in `docs/exec-plans/tech-debt-tracker.md`.

### How to Implement
1. Create `lib/mix/tasks/zaq.docs.check.ex`
2. Implement each sub-check as a private function
3. Add to `.github/workflows/ci.yml` as a separate CI job
4. Add `mix zaq.docs.check` to `mix precommit`
5. Write tests in `test/mix/tasks/`

### Hand to Claude Code
```
Implement a mix task `mix zaq.docs.check` as described in docs/harness-roadmap.md
Task 4. Check for dead links, missing cross-links, stale quality score, and tech
debt tracker sync. Add it to mix precommit and CI.
```

### Definition of Done
- `mix zaq.docs.check` passes on current repo
- CI fails if dead links found
- CI warns if quality score is stale
- Runs in under 5 seconds

---

## Task 5 — Agent-to-Agent Review Loop

**Impact:** +4 points | **Effort:** Medium | **Priority:** Medium

### Why
Agents currently open PRs and wait for human review. Pushing review effort to
agent-to-agent frees human attention for judgment-level decisions only.

### What to Build

#### 5a — Review checklist
Create `docs/REVIEW_CHECKLIST.md`:

```markdown
- [ ] No direct cross-service calls from BO (NodeRouter enforced)
- [ ] No plaintext sensitive fields (encryption enforced)
- [ ] Tests written for every new public function
- [ ] Relevant docs updated if behavior changed
- [ ] mix precommit passes
- [ ] E2E passes if change touches ingestion/config/telemetry
- [ ] No backwards layer dependencies introduced
- [ ] PR title follows Conventional Commits
```

#### 5b — Wire `agent-review` into WORKFLOW_AGENT.md
Update Phase 4 to invoke `agent-review` skill before opening any PR.
Agent must sign off before PR is opened.

#### 5c — Update reviewer agent file
Update `.claude/agents/agent-review.md` to reference `docs/REVIEW_CHECKLIST.md`
as its evaluation criteria.

### Hand to Claude Code
```
Create docs/REVIEW_CHECKLIST.md and update docs/WORKFLOW_AGENT.md Phase 4 to invoke
the agent-review skill before opening any PR, as described in docs/harness-roadmap.md
Task 5. Update .claude/agents/agent-review.md to use the checklist.
```

### Definition of Done
- Every agent PR includes a review comment referencing checklist items
- Agent does not open PR if review finds blocking issues
- Human sees review output in PR description

---

## Recommended Execution Order

| Order | Task | Score gain | Projected total |
|---|---|---|---|
| — | Current state | — | **84/100** |
| 1 | Update `docs/services/` | +4 | 88/100 |
| 2 | Custom linters | +6 | 94/100 |
| 3 | Run 3 real exec plans | +4 | 98 → capped at 96/100 |
| 4 | CI doc validation | +4 | 96/100 |
| 5 | Agent-to-agent review | +4 | 96/100 |

---

## What 100/100 Would Require

The remaining 4 points require infrastructure beyond docs and code:
- Agents booting isolated app instances per git worktree (Docker-per-task setup)
- Chrome DevTools Protocol wired into agent runtime (screenshot + DOM snapshot)
- Fully automated PR merge without human approval on green CI

Valid long-term goals. Not blocked by anything above — can be pursued in parallel
once the harness is stable at 96/100.