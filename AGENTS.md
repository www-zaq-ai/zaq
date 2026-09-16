# ZAQ Agent Entry Point

ZAQ is an AI-powered company brain built with Elixir/Phoenix. This file is the dispatcher, not a copy of every policy.

## Load instructions by task

- On a new environment, follow [agent workflow setup](docs/agent-setup.md) to configure and verify Context Mode, Serena and Beadwork before starting automated work.
- On every task, run `bw prime` and read the applicable sections of [the workflow](docs/WORKFLOW_AGENT.md). Check existing Beadwork issues before complex work.
- Before using tools, read the routing rules in [agent tools](docs/agent-tools.md). Read catalog/maintenance sections only when needed.
- Before changing documentation, agent guidance or project memories, read [documentation hygiene](docs/documentation.md); use the [docs index](docs/README.md) for navigation.
- Before designing or changing operations, read [Action reuse](docs/action-reuse.md); record reuse/extend/new/local-only evidence, or justified not-applicable. Never duplicate operations or automatically expose Actions as agent tools.
- Read the required documents below **before the affected work**. Links are not automatic imports. Do not load the entire map.
- Read relevant sections once; reuse unchanged instructions already in context. After compaction, recover applicable policies and verify current files, Git and Beadwork state before acting.
- Delegated prompts must name applicable policy files and require reading them when not inherited. Never assume a subagent has this context or the same tools.

## Essential constraints

- Never push directly to `main`; changes go through a PR. Commit/push/merge only when authorized.
- All cross-service BO calls use `NodeRouter.dispatch/1` with `%Zaq.Event{}`, not direct module calls.
- Read a module's `@moduledoc` before adding a function; respect its responsibility.
- Before touching keys, tokens, passwords or encrypted fields, read [system configuration](docs/services/system-config.md).
- Before changing `lib/zaq/agent/`, read the [Agent service checks](docs/services/agent.md#harness-critical-checks-for-coding-agents) and applicable service sections. Nil identity is never implicit permission.
- For BO/UI work, read [DESIGN.md](DESIGN.md) first; use [BO components](docs/bo-components.md) for layout, flash and PR checklist. Do not load design docs for unrelated work.
- For code changes, follow [testing guidance](docs/testing-approach.md), including property tests for invariants/broad input spaces and the human UX/UI approval gate for new feature E2E. Never weaken existing assertions to hide regressions.
- Validation summary: `mix q` (includes formatting) plus isolated tests per issue; final `mix precommit` **before requesting final human approval**. Read and follow the authoritative [validation lifecycle](docs/WORKFLOW_AGENT.md#phase-4--validate), including failure handling, coverage and repeat gates. Documentation-only work needs no application tests.
- Batch independent related operations in one message; sequence dependent operations safely.
- Keep responses under 500 words. Write artifacts to files; report paths with concise descriptions rather than inline artifacts.

## Tool boundary summary

**Serena selects relevant code; Context Mode selects relevant operational information.** Use Serena overviews, symbols and references for source understanding; use native `ctx_*` tools for large results, aggregate analysis and session recall. Use targeted reads/patches for Markdown or configuration. Host editing requirements take precedence.

Do not index the source tree merely to find a symbol. Do not dump large logs or tool output into context. Follow [agent tools](docs/agent-tools.md) for mandatory routing, bounded fallbacks, memory ownership and maintenance commands.

## Policy owners and task map

Edit policies at their owner; other docs should link to them, not restate procedures. Short reminders here are routing aids, not independent policy definitions. If documents conflict, flag the drift and consult the owner; never override host/system instructions.

| When / need                                              | Required owner or guide                                                                              |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Workflow, validation timing, approvals, coverage handoff | [Agent workflow](docs/WORKFLOW_AGENT.md)                                                             |
| Tool routing, fallback, memory, Context Mode commands    | [Agent tools](docs/agent-tools.md)                                                                   |
| Documentation ownership, organization and memory hygiene | [Documentation policy](docs/documentation.md); [index](docs/README.md)                               |
| New complex plan                                         | [Planning strategy](docs/exec-plans/PLAN_STRATEGY.md); durable steps in Beadwork, not new plan files |
| Action discovery and reuse                               | [Action reuse](docs/action-reuse.md)                                                                 |
| Test design, isolation, property tests, E2E approval     | [Testing handbook](docs/testing-approach.md)                                                         |
| Project structure / architecture                         | [Project](docs/project.md), [architecture](docs/architecture.md)                                     |
| Naming / module design / code quality                    | [Conventions](docs/conventions.md), [code quality](docs/code-quality.md)                             |
| Elixir, Ecto, Mix / Phoenix, LiveView                    | [Elixir](docs/elixir.md), [Phoenix](docs/phoenix.md)                                                 |
| Environment setup / agent selection                      | [Agent workflow setup](docs/agent-setup.md), [dev setup](docs/dev-setup.md)                          |
| Git conventions / contribution process                   | [Git workflows](docs/workflows.md), [contributing](CONTRIBUTING.md)                                  |
| E2E execution and fixtures                               | [E2E testing](docs/e2e-testing.md)                                                                   |
| Domain quality / existing debt                           | [Quality score](docs/QUALITY_SCORE.md), [debt tracker](docs/exec-plans/tech-debt-tracker.md)         |
| Historical decisions / harness roadmap                   | [Completed plans](docs/exec-plans/completed/), [roadmap](docs/plans/harness-roadmap.md)              |

### Service-specific work

Read the relevant service guide before changing its domain; inspect only the applicable sections.

| Domain                                         | Guide                                               |
| ---------------------------------------------- | --------------------------------------------------- |
| Agent pipeline, LLM, retrieval, answering      | [Agent](docs/services/agent.md)                     |
| BO authentication / authorization              | [BO auth](docs/services/bo-auth.md)                 |
| Channels and adapters                          | [Channels](docs/services/channels.md)               |
| Engine, conversations, notifications, dispatch | [Engine](docs/services/engine.md)                   |
| Ingestion, chunking, embedding                 | [Ingestion](docs/services/ingestion.md)             |
| Onboarding, provisioning, consent              | [Onboarding](docs/services/onboarding.md)           |
| Add-ons and feature gating                     | [Add-ons](docs/services/addons.md)                  |
| Secrets, encryption, configuration             | [System config](docs/services/system-config.md)     |
| Telemetry and metrics                          | [Telemetry](docs/services/telemetry.md)             |
| Record materialization                         | [Materialization](docs/services/materialization.md) |
| Workflow DAGs, triggers, runs                  | [Workflows](docs/services/workflows.md)             |

Beadwork owns durable AI plans/progress; GitHub owns overall project issues/PRs/discussions. Repository documentation owns standards; memory is supporting recall, not a substitute.
