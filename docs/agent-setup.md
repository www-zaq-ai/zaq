# Agent Workflow Setup

Contributors using an automated coding-agent workflow must set up **Context Mode,
Serena, and Beadwork** so their agent can follow ZAQ's repository requirements.
These are development-workflow tools, not dependencies of the running ZAQ application.
This guide is for both contributors and agents preparing a new environment.

## Required tools

Follow each project's current installation and coding-host integration instructions:

| Tool and official instructions | Role in ZAQ's workflow |
| --- | --- |
| [Context Mode](https://github.com/mksglu/context-mode) | Process large command output and logs without flooding context; support session recall and validation execution |
| [Serena](https://github.com/oraios/serena) | Semantic code navigation, Elixir symbol/reference queries and supporting project memories |
| [Beadwork (`bw`)](https://github.com/jallum/beadwork) | Durable plans, issue dependencies, progress and blockers shared across agent sessions |

Installation commands, releases, prerequisites and host-specific configuration
belong to those upstream projects. Use their current guidance rather than copying
an installation snippet or version pin into this repository. Installing a tool
alone is not enough: the coding host must expose the required capabilities to the agent.

## Prepare a new environment

1. **Prepare the application checkout.** Follow [development setup](dev-setup.md)
   and the linked application prerequisites. Tool setup does not replace Elixir,
   database, Python or browser-test setup required for the task.
2. **Read the repository entry point.** Start at [AGENTS.md](../AGENTS.md), then read
   the applicable [tool-routing rules](agent-tools.md) and [workflow](WORKFLOW_AGENT.md).
   Host configuration must make these instructions accessible to the agent.
3. **Connect Context Mode to the coding host.** Follow its upstream integration
   guide for that host. Confirm the execution/search tools and diagnostics are
   exposed; do not assume every host uses the same plugin, hooks or MCP setup.
4. **Activate this checkout in Serena.** Reuse the committed
   [project configuration](../.serena/project.yml) and [project memories](../.serena/memories/).
   Verify Elixir language support and that the active project is the intended
   checkout/worktree. Do not overwrite shared configuration or regenerate existing
   memories just because the machine is new.
5. **Make Beadwork available to the agent.** Ensure `bw` is on the agent's execution
   PATH. Follow upstream guidance for using an existing repository, then run
   `bw prime` from the project root and inspect the existing issues. Reuse this
   project's tracking state rather than initializing a separate issue store.

Agents must obtain permission before installing software, changing user-level
configuration or enabling new integrations. Keep machine-local paths and credentials
out of shared configuration and documentation; never copy another contributor's
personal host configuration wholesale.

## Verify readiness

Check capabilities from the **actual agent session**, not only a separate terminal:

- **Context Mode:** its diagnostics succeed and the agent can execute a small,
  read-only command through its execution tool. See [tool maintenance](agent-tools.md#maintenance-commands)
  for repository diagnostic commands.
- **Serena:** read its initial instructions, confirm ZAQ is active, and retrieve a
  symbol overview from an Elixir source file such as `lib/zaq/event.ex`. A running
  server alone does not prove semantic navigation works. Inspect existing memories
  before deciding whether onboarding is needed.
- **Beadwork:** `bw prime` and issue listing work in this checkout, exposing the
  existing project rather than an unrelated or newly created tracker.
- **Repository workflow:** the agent can read the policy owners and run the task's
  required commands. Tool readiness does not prove application tests or quality
  gates pass; those remain governed by [the validation lifecycle](WORKFLOW_AGENT.md#phase-4--validate).

If a tool, language server or integration is unavailable, report the missing
capability and follow the bounded fallback in [agent tools](agent-tools.md).
Do not claim the automated workflow is fully configured, silently skip required
checks, or move durable plans into chat because a prerequisite is missing.

## Policy boundaries

This document owns ZAQ-specific environment setup and readiness for agent tools.
[Agent tools](agent-tools.md) owns how they are used;
[the workflow](WORKFLOW_AGENT.md) owns planning, validation and approvals;
[documentation hygiene](documentation.md) owns documentation and memory organization.
