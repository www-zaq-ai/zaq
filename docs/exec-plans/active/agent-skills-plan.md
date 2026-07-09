# Plan: Agent Skills (DB-backed skills attachable to configured agents)

Status: PLANNED (2026-07-02) · Branch: `feat/add-agent-skills`
Discovery: [jido-ai-skills-discovery.md](jido-ai-skills-discovery.md)

## Goal

Admins can create/manage **skills** (name, description, markdown body/instructions, a set of tools
from `Zaq.Agent.Tools.Registry`, tags) in the BO, attach the same skill to multiple configured
agents, search skills by tags — and attached skills actually take effect at runtime (tools +
prompt injection via the jido_ai skill machinery).

## Requirements (user) + gaps found during planning

User-stated:
- New DB table for skill details
- CRUD operations
- Dedicated BO page
- Skills reference tools from the tool registry
- Same skill attachable to many agents
- Tag search inside the agent's skill picker

Gaps added (were missing):
1. **Runtime wiring** — `Factory.runtime_config/1` must merge skill tool modules into `tools` and
   append the rendered skill bodies (`Jido.AI.Skill.Prompt`-style block) to `system_prompt`;
   `ServerManager` fingerprint must cover skill config so changes trigger lazy restart;
   `RuntimeSync` must refresh on skill edits.
2. **Skill body** — the markdown instruction body is the heart of a skill (what gets injected into
   the LLM prompt); the user list only had tools + tags.
3. **NodeRouter events** — BO LiveView cannot call the Agent context directly; new
   `%Zaq.Event{}` types + dispatch handlers are required (pattern: `agents_live.ex:264`).
4. **Agent↔skill linkage shape** — decision below.
5. **Tool-key validation + ghost handling** — validate `tool_keys` against
   `Tools.Registry.valid_tool_key?/1`; tolerate ghosts like `ghost_keys/1` does today.
6. **Deletion/deactivation semantics** — what happens to agents referencing a deleted skill
   (soft-delete via `active` flag; runtime skips inactive/missing skills, UI shows warning).
7. **BO auth + navigation** — route scope, sidebar entry for the new page.
8. **Name constraints** — jido `Spec` enforces name regex/max lengths; mirror them in the changeset
   so DB skills stay convertible to `%Jido.AI.Skill.Spec{}`.
9. **Tests** — ≥95% coverage on touched files; e2e through the real seam (skill attached → ask →
   prompt/tools visible in LLM request), per testing-approach.md.

## Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| D1 | Agent↔skill link | `enabled_skill_ids {:array, :integer}` on `configured_agents` | Mirrors existing `enabled_tool_keys` / `enabled_mcp_endpoint_ids` pattern; many-to-many satisfied; no join-table churn in Factory/ServerManager |
| D2 | jido integration | Convert DB record → `%Jido.AI.Skill.Spec{}` at runtime; render prompt block ourselves (Prompt.render-equivalent); skip ETS `Skill.Registry` for v1 | DB is the source of truth; ETS registry adds a sync problem without benefit |
| D3 | Tool semantics | Skill tools are **additive** to the agent's `enabled_tool_keys` (union, deduped) | Matches jido `tools_from_skills/1` semantics; least surprise |
| D4 | Runtime propagation (revised 2026-07-02, per user) | Hot runtime patch tier, same as tools/MCP: tools via `RuntimeSync.sync_agent_configured_tools/3`, prompt via per-ask `ensure_system_prompt/2` with effective prompt (job + skills block). Skills excluded from restart fingerprint. | Mirrors the established `:enabled_tool_keys`/`:enabled_mcp_endpoint_ids` pattern; no restarts for skill changes; prompt self-heals at ask time |

## Parts

### Part 1 — Schema + migration `agent_skills` ✅ DONE (2026-07-02)
- [x] Migration `priv/repo/migrations/20260702000000_create_agent_skills.exs`: name (unique),
      description, body (text), `tool_keys`/`tags` string arrays (GIN index on tags), `active`.
- [x] `Zaq.Agent.Skill` (`lib/zaq/agent/skill.ex`): required name/body; jido kebab-case name
      regex + 64-char max, description ≤1024; `tool_keys` validated against
      `Tools.Registry.valid_tool_key?/1` (ghost-tolerant like ConfiguredAgent); tags normalized.
- [x] Tests: `test/zaq/agent/skill_test.exs` (16 tests green); `mix q` clean.

### Part 2 — Context CRUD + tag search ✅ DONE (2026-07-02)
- [x] `Zaq.Agent.Skills` context (`lib/zaq/agent/skills.ex`) — dedicated module (Zaq.Agent's
      moduledoc is scoped to configured agents): list/list_active/get/get!/get_by_ids (ghost-
      dropping)/create/update/delete/change + `search_skills/1` (tag array-overlap via `&&`,
      ILIKE q with wildcard escaping, active filter).
- [x] Tests: `test/zaq/agent/skills_test.exs` (19 tests green).
- [x] NodeRouter: no new event actions needed for plain CRUD — BO uses the existing generic
      `:invoke` passthrough (`InternalBoundaries.invoke_request/1`, no allowlist). Sync-aware
      `skill_updated`/`skill_deleted` actions land in Part 4 with RuntimeSync.

### Part 3 — ConfiguredAgent linkage ✅ DONE (2026-07-02)
- [x] Migration `20260702000001_add_enabled_skill_ids_to_configured_agents.exs` (int array,
      GIN index for Part 4's "agents referencing skill X" lookup).
- [x] `enabled_skill_ids` field + `normalize_skill_ids/1` (uniq, mirrors mcp ids; ghost-tolerant —
      no FK, runtime drops missing ids via `Skills.get_skills_by_ids/1`). Tests added (55 green).

### Part 4 — Runtime wiring ✅ DONE (2026-07-02)

Skills follow the **hot runtime patch** tier (same as `:job`, `:enabled_tool_keys`,
`:enabled_mcp_endpoint_ids`) — NOT the restart fingerprint. See D4 (revised).

- [x] Effective-config single home in `Zaq.Agent.Skills`: `enabled_for_agent/1` (active skills,
      ghost/inactive dropped, no DB hit when ids empty), `effective_tool_keys/2` (agent ∪ skill
      keys, registry-ghost skill keys filtered), `effective_system_prompt/2` +
      `render_prompt_block/1` (jido Prompt-style header + `## name` sections).
- [x] `Factory.runtime_config/1` uses effective keys + effective prompt;
      `ask_with_config/4` recomputes the effective prompt per ask via `ensure_system_prompt/2`
      (skill body edits self-heal on next ask).
- [x] `RuntimeSync`: `sync_agent_configured_tools/3` reconciles against the skill-augmented set
      (opt `:skills_module` for tests); `:enabled_skill_ids` added to `no_runtime_change?/2`;
      new `agent_skill_updated/3` / `agent_skill_deleted/2` persist + fan out tool re-sync to
      active agents via `Zaq.Agent.list_agents_with_skill/1` (new).
- [x] `Zaq.Agent.API`: new `:agent_skill_updated` / `:agent_skill_deleted` event actions
      (mirror configured_agent ones).
- [x] `ServerManager` fingerprint: unchanged — skills deliberately excluded (verified).
- [x] Tests: Skills composition (skills_test), RuntimeSync skill lifecycle + skill-tool sync +
      runtime-change detection (runtime_sync_test), Factory skill union/prompt/ghost tests
      (factory_test). Full agent suite 822 tests green; credo clean.

### Part 5 — BO Skills page ✅ DONE (2026-07-02)
- [x] `ZaqWeb.Live.BO.AI.SkillsLive` + heex: list table (name/desc/tags/tool count/status),
      free-text + tag filter, create/edit form (name, tags, description, markdown body, tool
      picker fed from `Tools.Registry.tools/0` as a separate assigns-backed mini-form, active
      toggle), delete with confirm. Reads direct (`Skills.search_skills/1`); create via `:invoke`,
      update/delete via `:agent_skill_updated`/`:agent_skill_deleted` NodeRouter actions.
- [x] Route `live "/skills"` in the `:bo` live_session (AuthHook-protected); sidebar "Skills"
      entry in the AI section (`bo_layout.ex`, `ai_section_active?/1` extended).
- [x] Tests: `test/zaq_web/live/bo/ai/skills_live_test.exs` (9 tests green — render, list,
      filter, create, validation errors, edit, tool add/remove, delete, cancel).

### Part 6 — Agent form integration ✅ DONE (2026-07-02)
- [x] Skills section in `agents_live` form (mirrors MCP picker): `+ Add skills` modal with
      `searchable_select` (labels include tags → tag search inside the picker), chips panel with
      ghost "Removed" / "Inactive" badges, hidden inputs → `enabled_skill_ids` via changeset;
      `normalize_skill_ids` in attrs parsing; picker offers active unattached skills only.
- [x] Tests: 4 new tests in `agents_live_test.exs` (attach+persist, remove, ghost warning,
      picker filtering/tag labels) — 38 tests green.

### Part 7 — Tests + docs + close-out
- [ ] Unit: schema/changeset, context CRUD + tag search, Factory merge logic (tools union,
      prompt injection, inactive/ghost skills skipped).
- [ ] LiveView tests for skills page + agent picker.
- [ ] E2E through the real seam: agent with skill → `ask` → assert LLM request contains skill tools
      + skill body (no stubbing of the hop under test; vary payload shapes).
- [ ] Property test: tag search normalization invariants.
- [ ] Update `docs/services/agent.md`; `mix format` + `mix q`; ≥95% coverage on touched files;
      move this plan to `docs/exec-plans/completed/` with Decisions Log filled.

### Part 8 — Skill MCP endpoints ✅ DONE (2026-07-08, per user)

Skills gain an `enabled_mcp_endpoint_ids` set, mirroring `enabled_tool_keys`. Attached skills
contribute MCP endpoints to the agent's effective set at runtime, propagated through the same
hot-patch path. **Removal follows the agent path** (per user): additive sync + diff-driven
unsync — but overlap-safe, since a skill is now a *second* MCP source (an endpoint still provided
by the agent itself or another attached skill is never unsynced).

- [x] `Skill` schema: `enabled_mcp_endpoint_ids {:array, :integer}` + dedup/normalize in changeset;
      migration `20260708000000_add_enabled_mcp_endpoint_ids_to_agent_skills` (GIN index).
- [x] `Skills.effective_mcp_endpoint_ids/2` (agent own ∪ skill ids, deduped), mirrors
      `effective_tool_keys/2`.
- [x] `RuntimeSync.sync_agent_mcp_assignments/3` reads the effective set (`:skills_module` opt);
      boot (`hydrate_mcp_assignments`) and hot-patch both go through it → skills apply at boot.
- [x] `agent_skill_updated`/`agent_skill_deleted`: capture the skill's previous MCP ids, compute
      the removed set, `patch_skill_runtime/3` unsyncs per impacted agent — but only endpoints no
      longer in *that agent's* effective set (overlap-safe via `unsync_skill_removed_endpoints`).
      `patch_agent_runtime` removal made effective-aware too (`still_effective_mcp_endpoint_ids`).
- [x] BO skill form: MCP picker mirroring the tool picker (shared `selected_mcp_panel/1` moved to
      `ZaqWeb.Components.AgentToolsPicker`; `open/close/add_mcp_from_picker`, `remove_mcp`).
- [x] Tests: schema dedup, `effective_mcp_endpoint_ids`, RuntimeSync effective-sync + skill-driven
      unsync + overlap-safety, skills_live MCP add/remove persistence. 183 tests green; credo clean.

## Decisions Log

- 2026-07-02 — Plan created; D1–D4 recorded above, pending user confirmation on D1/D3.
- 2026-07-08 — Skills support MCP endpoints (Part 8). Per user: removal mirrors the agent path
  (additive sync + diff-driven unsync). Added overlap-safety because skills introduce a second MCP
  source — an endpoint still supplied by the agent or another skill is never unsynced.
- 2026-07-02 — D4 revised per user: skills wired like tools/MCP (hot runtime patch, not restart
  fingerprint). Tools reconcile via `sync_agent_configured_tools/3`; prompt recomputed per ask in
  `ensure_system_prompt/2`. Added skill-record mutation sync (skill edit → sync all referencing
  live servers) since that trigger doesn't exist in the tools/MCP flow.
