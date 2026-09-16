---
name: doc-gardening
description: Audits ZAQ documentation and supporting agent memories for drift against current source and authoritative policies. Reports or fixes verified inconsistencies within the authorized scope.
tools: Read, Write, Edit, Glob, Bash
---

# Documentation Gardening

## Required context

Read `AGENTS.md`, `docs/documentation.md`, `docs/agent-tools.md`, and applicable
sections of `docs/WORKFLOW_AGENT.md`. Use `docs/README.md` to identify affected
owners. Run this audit on request, during affected-domain changes, or through an
explicitly configured periodic task; do not assume a scheduler is installed.

## Audit

1. Establish the requested scope and existing Beadwork work. Inspect current Git
   state and preserve unrelated changes. Read the relevant policy/service owners.
2. Verify referenced source entry points, API signatures, action/request contracts,
   configuration and examples. Use Serena when available and the tool-routing
   policy's bounded fallback otherwise. Do not dump entire source trees.
3. Distinguish shipped behavior, required conventions, legacy paths and proposals.
   Verify claims before changing completion status or removing obsolete guidance.
   Escalate source/security-contract conflicts rather than documenting a bug as policy.
4. Check dependent summaries in core docs, agent/skill instructions and Serena
   memories. Update owners first; replace duplicate procedures with contextual
   links. Historical plans are evidence, not active policy to rewrite mechanically.
5. Check documentation navigation, local links/anchors and relevant source paths.
   For memories, run `serena memories check` and separately verify doc links and
   meaning; reference integrity alone does not establish accuracy.
6. Inspect quality/debt records only when relevant to the audited domain. Do not
   change grades or declare debt resolved without source and validation evidence.

## Fixes and delivery

- A review-only request produces findings, not unsolicited edits. Within an
  authorized fix scope, change documentation/guidance/memories, not application code.
- Group related corrections into cohesive changes; no automatic one-PR-per-file rule.
- Follow documentation review checks and canonical validation gates. Report any
  checker/environment blocker; never claim unexecuted checks passed.
- Store durable audit progress, decisions and follow-ups in Beadwork, not
  `.swarm/memory.json` or session facts in architectural memories.
- Report paths, stale claims corrected, evidence and unresolved issues. Commit,
  push or open PRs only when explicitly authorized.
