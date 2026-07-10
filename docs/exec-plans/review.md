## PR Review: feat(agent): add configurable agent skills with BO management UI

### A. Inline Review Comments

---

**Comment 1** — Medium — `lib/zaq_web/components/agent_tools_picker.ex:47-163`

**Title:** Shared component uses hardcoded hex colors instead of ZAQ design tokens

**Problem:** The new `agent_tools_picker.ex` component uses Tailwind arbitrary hex values (`text-[#9a958c]`, `border-[#efece6]`, `bg-[#faf8f5]`, `text-[#3e3b36]`, etc.) throughout its markup, while the rest of the BO surfaces (including `skills_live.html.heex` and `agents_live.html.heex`) use `var(--zaq-*)` CSS custom properties or hardcoded `style=` attributes with tokens. This is a shared component imported by both agents and skills LiveViews, so the color hardcoding propagates to all call sites.

**Why it matters:** Prevents dark-mode support and introduces visual drift. The same PR includes a design-migration commit, making this immediately at odds with project conventions.

**Suggested fix:** Replace all arbitrary hex values with `var(--zaq-*)` semantic tokens matching the existing patterns in `skills_live.html.heex` (e.g., `var(--zaq-text-color-body-default)`, `var(--zaq-text-color-body-tertiary)`, `var(--zaq-border-color-default)`).

---

**Comment 2** — Medium — `lib/zaq/agent/skill.ex:58-67`

**Title:** `normalize_mcp_endpoint_ids` accepts any positive integer without existence validation

**Problem:** The normalizer only filters `&1 > 0` but never checks whether the endpoint ID actually maps to an existing `MCP.Endpoint`. In contrast, `ConfiguredAgent.changeset` delegates to `Zaq.Agent.validate_mcp_endpoint_assignments/1` which queries `MCP.get_mcp_endpoint/1` to catch unknown IDs at save time.

```elixir
defp normalize_mcp_endpoint_ids(changeset) do
    ids = ... |> Enum.filter(&(is_integer(&1) and &1 > 0))  # no existence check
```

**Why it matters:** An admin can assign a non-existent endpoint ID to a skill and receive no save-time error. The invalid ID is silently skipped at runtime sync (`sync_agent_mcp_assignments` returns `:skipped` for unknown endpoints), so the configuration error is invisible until runtime behavior differs from expectation. This wastes admin debugging time.

**Suggested fix:** Either add a `validate_mcp_endpoint_ids` validation function that checks each ID against `MCP.get_mcp_endpoint/1` (mirroring `ConfiguredAgent`), or document clearly in the moduledoc/function docs that endpoint assignments are validated lazily at sync time.

---

**Comment 3** — Low — `assets/vendor/highlight.js:1`

**Title:** Missing license attribution for vendored highlight.js bundle

**Problem:** `assets/vendor/highlight.js` contains highlight.js v11 (BSD-3-Clause licensed) with no license header comment in the file and no companion LICENSE file in the directory. `assets/css/highlight.css:1-7` documents the vendor source but doesn't reference the license.

**Why it matters:** Open-source license compliance. BSD-3-Clause requires reproduction of the copyright notice and disclaimer in distributions.

**Suggested fix:** Add a `assets/vendor/highlight.js.LICENSE` file containing the BSD-3-Clause text and copyright, or prepend a `/* SPDX-License-Identifier: BSD-3-Clause ... */` comment block to the minified file.

---

**Comment 4** — Low — `lib/zaq_web/live/bo/ai/skills_live.ex:189-193`

**Title:** Skill creation dispatches through `:invoke` (bypasses RuntimeSync) while update/delete use `RuntimeSync`

**Problem:** Creating dispatches `Event.new(%{module: Skills, function: :create_skill, args: [attrs]}, :agent, opts: [action: :invoke])` — calling `Skills.create_skill/1` directly via `InternalBoundaries.invoke_request/1`, which bypasses `RuntimeSync`. Update and delete use `:agent_skill_updated`/`:agent_skill_deleted` actions that route through `RuntimeSync` for tool/MCP fan-out. While functionally correct (a newly created skill has no agent references yet), the asymmetry could confuse maintainers who might wonder why create doesn't follow the same pattern.

**Suggested fix:** Document the rationale in a comment, or route creation through a `RuntimeSync.agent_skill_created/2` (no-op runtime-wise, but consistent in the dispatch path) to make the pattern uniform.

---

### B. General PR Conversation Comments

---

**General Comment 1** — Low — Cross-module

**Title:** `list_agents_with_skill/1` continues the in-memory filter pattern from `list_agents_with_mcp_endpoint/1`

**Problem:** `Zaq.Agent.list_agents_with_skill/1` (`lib/zaq/agent.ex:49-55`) loads all agents and filters by `enabled_skill_ids` in memory — matching the existing `list_agents_with_mcp_endpoint/1` pattern. For typical deployments with dozens-to-hundreds of agents this is fine, but as agent count grows, this becomes an N+1-load concern (both these functions are called during runtime sync fan-out, one query each per skill/endpoint update).

**Recommendation:** Not a blocker for this PR, but consider filing follow-up tech debt to add a database-level filter or a raw SQL query for agent-skill/agent-endpoint assignments using PostgreSQL array containment operators (`@>`).

---