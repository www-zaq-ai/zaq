# Documentation Organization and Hygiene

This is the authoritative policy for organizing, authoring, and maintaining ZAQ
documentation and its supporting project memories. [The documentation index](README.md)
provides navigation; it does not duplicate these rules.

## Information ownership

| Information | Authoritative home |
| --- | --- |
| Product introduction and installation | Root `README.md`; detailed setup in `docs/dev-setup.md` |
| Agent-tool environment setup and readiness | `docs/agent-setup.md`; installation/integration instructions remain upstream |
| Project/source map | `docs/project.md` |
| Cross-service architecture, roles and dispatch | `docs/architecture.md` |
| Domain contracts, responsibilities and security constraints | Relevant `docs/services/` guide; code-level API contracts in module/function docs |
| Development standards and procedures | The policy owners linked from `AGENTS.md`, such as conventions, testing and workflow |
| Operational instructions and user tasks | `docs/operations/` and `docs/guides/` |
| UI foundations and visual contracts | Sources identified by `DESIGN.md`; BO mechanics in `docs/bo-components.md` |
| Agent entry points and specialized roles | `AGENTS.md`, tool-specific entry points, skills and agent definitions: route to owners, do not redefine them |
| Durable implementation plans, progress and blockers | Beadwork; GitHub owns overall issues/PRs/discussions |
| Historical designs and decisions | Existing design/plan archives, clearly distinguished from current contracts |
| Agent orientation and source discovery | Serena project memories: concise supporting notes, not another architecture manual |

Keep one authoritative owner for each rule or procedure. Other documents may
include a short contextual reminder with a link, but must not maintain another
version of the procedure. Update the owner first, then its links and summaries.
Do not move repository standards into a tool-specific memory or agent prompt.

## Structure and navigation

- Keep `docs/README.md` task-oriented and link-based. Add or update its relevant
  entry when a guide is introduced, renamed, or retired.
- Keep `AGENTS.md` a short task dispatcher. `CLAUDE.md` and other tool entry points
  should route to it rather than accumulate architecture tables or alternate rules.
- Architecture describes the system and cross-domain seams; service guides explain
  the owning domain's contracts and invariants. Do not reproduce every public
  function or file: link to source entry points and ExDoc for API detail.
- Operational guides explain prerequisites, commands, side effects and recovery.
  Link to the workflow for validation timing instead of defining separate gates.
- Use relative Markdown links for repository documents and stable headings for
  anchors. Source paths must be repository-relative and verified. Avoid durable
  references to line numbers, which drift with unrelated edits.
- Split documents by responsibility or audience, not an arbitrary line limit.
  Give long guides descriptive sections so readers can load only what they need.

## Current, proposed and historical information

- Describe shipped behavior as current only after checking the implementation and
  relevant tests. Verify dispatch actions, request shapes and permissions at the
  actual role API, not by copying a similar example.
- Distinguish **required convention** from **legacy implementation**. An old helper
  still existing does not make it the convention for new work; a desired migration
  does not mean all callers have migrated.
- Label unimplemented designs as proposed and link their tracking issue. Preserve
  historical documents as historical evidence, not instructions for current work.
  New execution plans belong in Beadwork per [planning strategy](exec-plans/PLAN_STRATEGY.md).
- When source and a documented security/architecture contract disagree, investigate
  and record the conflict. Do not silently rewrite the contract to legitimize a bug,
  or claim the source already implements an intended rule. Escalate unresolved intent.
- Link version-sensitive facts to `.tool-versions`, `mix.exs`, `mix.lock` or the
  relevant package/configuration file. Avoid copying version pins into agent roles
  and memories. A useful stack overview may summarize supported major versions.
- Claims that a rule is mechanically enforced must name the enforcing check or test.
  Otherwise describe it as a design/review constraint, not guaranteed enforcement.

## Change and review checklist

1. Identify affected owners before editing; read [tool routing](agent-tools.md) and
   the relevant service/policy sections. Record Action reuse as not applicable for
   documentation-only work without executable operation changes.
2. Update behavior/architecture documentation alongside the change, before review
   completion. Record intentionally deferred documentation with an issue and scope.
3. Verify referenced modules, paths, commands, request/result examples and local
   links/anchors. Label schematic examples and their assumed inputs; do not present
   pseudocode or destructive commands as harmless runnable checks.
4. Search dependent summaries, agent instructions and memories for the old rule.
   Correct active guidance; do not mechanically rewrite historical records.
5. Group related consistency fixes into a cohesive reviewable change. Do not require
   one PR per document when those documents describe the same contract.
6. Check local links and anchors in changed documents and run `serena memories check`
   from the project root when memory references change. That command checks memory
   reference integrity, **not** semantic accuracy or all repository Markdown links.
7. Follow the [validation lifecycle](WORKFLOW_AGENT.md#phase-4--validate), including
   its documentation-only exceptions and final gate. Record what was checked and
   any failures/blockers; never claim an unavailable checker ran. Git/PR mutations
   still require authorization under that workflow.

Review stale paths, unsupported examples and contradictory instructions during
domain changes; periodic gardening supplements, rather than replaces, these checks.
Keep audit progress and follow-ups in Beadwork, not a parallel `.swarm` ledger.

## Serena memory hygiene

- The repository owns architecture and standards. Memories provide a discovery
  graph rooted at `core`: what a subsystem owns, where its authoritative guide and
  source entry points are, and a few non-obvious pitfalls.
- Prefer a short owner link plus useful orientation over either a copied manual or
  a bare list of links. Do not copy full validation sequences, mutable dependency
  versions, exhaustive module catalogs, or task-local progress into memories.
- Add a memory only when stable knowledge avoids meaningful rediscovery. Keep
  related notes under a domain topic; update existing notes before adding another.
- Use backticked `mem:` references, such as `mem:engine/core`, with a description of
  what the target helps discover. Entry memories route readers; individual memories
  do not need a repeated “when to read this” section.
- Refresh affected memories when ownership or navigation changes, after updating
  the authoritative documents. Short reminders must remain consistent with owners.
- Memory naming, reference syntax and tool-specific maintenance entry points may
  be summarized in `memory_maintenance`; that memory links here instead of creating
  a competing documentation policy. Tool behavior/fallbacks remain owned by
  [agent tools](agent-tools.md#memory-and-delegation).
