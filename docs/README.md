# ZAQ Documentation

Start with the guide for your task; this index is navigation, not another policy.
For documentation changes, follow [documentation organization and hygiene](documentation.md).
Coding agents start at [AGENTS.md](../AGENTS.md).

## Understand and run ZAQ

- [Product overview and local quick start](../README.md)
- [Docker deployment, persistent storage and production HTTPS](operations/deployment.md)
- [Project and source map](project.md)
- [Architecture, node roles and event dispatch](architecture.md)
- [Development setup and commands](dev-setup.md)
- [Database extension provisioning](database-setup.md)
- [Agent workflow setup: Context Mode, Serena and Beadwork](agent-setup.md)
- [User and integration guides](guides/)
- [Operational guides](operations/)

## Develop and validate

- [Contributing](../CONTRIBUTING.md), [Git workflows](workflows.md) and [release maintenance](workflows.md#releases)
- [Agent workflow and validation gates](WORKFLOW_AGENT.md)
- [Tool routing and memory boundaries](agent-tools.md)
- [Conventions](conventions.md), [code quality](code-quality.md), [Elixir](elixir.md), [Phoenix](phoenix.md)
- [Action discovery and reuse](action-reuse.md)
- [Testing handbook](testing-approach.md) and [E2E execution/fixtures](e2e-testing.md)
- [Design system](../DESIGN.md), [BO component mechanics](bo-components.md), [list selection](list-selection.md)

## Domain guides

| Domain | Guide |
| --- | --- |
| Agent execution, retrieval and tools | [Agent](services/agent.md) |
| Routing, conversations and coordination | [Engine](services/engine.md), including [personal grant sequences](services/personal-grant-sequences.md) |
| Provider bridges and integrations | [Channels](services/channels.md) |
| Documents, chunking and search | [Ingestion](services/ingestion.md) |
| Mounted filesystem ownership | [Storage architecture](architecture.md#storage-and-materialization) |
| Record materialization handles | [Materialization](services/materialization.md) |
| Workflow DAGs and execution | [Workflows](services/workflows.md) |
| Notification delivery | [Notifications](services/notifications.md) |
| BO authentication and authorization | [BO auth](services/bo-auth.md) |
| Runtime settings and secrets | [System configuration](services/system-config.md) |
| Provisioning and consent | [Onboarding](services/onboarding.md) |
| Add-ons and hooks | [Add-ons](services/addons.md), [hooks](services/hooks.md) |
| Metrics and dashboards | [Telemetry](services/telemetry.md) |

## Planning and historical context

- [Planning strategy](exec-plans/PLAN_STRATEGY.md): new execution plans and progress belong in Beadwork.
- [Quality assessment](QUALITY_SCORE.md) and [debt tracker](exec-plans/tech-debt-tracker.md).
- [Completed plan archive](exec-plans/completed/), [design/roadmap documents](plans/), and [UX artifacts](ux/)
  provide historical or proposed context; verify status before treating them as current contracts.
