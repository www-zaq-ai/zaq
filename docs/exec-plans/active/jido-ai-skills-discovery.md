# Discovery: jido_ai Skills — enabling skills inside ZAQ agents

Status: discovery complete (2026-07-02). No code changes yet.

## What jido_ai provides

The skill subsystem lives in `deps/jido_ai/lib/jido_ai/skill.ex` + `deps/jido_ai/lib/jido_ai/skill/*.ex`.
It is a **unified skill abstraction** supporting two flavors:

### 1. Compile-time module skills

```elixir
defmodule MyApp.Skills.WeatherAdvisor do
  use Jido.AI.Skill,
    name: "weather-advisor",
    description: "Provides weather-aware travel and activity advice.",
    license: "MIT",
    allowed_tools: ~w(weather_geocode weather_forecast),
    actions: [MyApp.Actions.Weather.Forecast],   # Jido.Action modules bundled with the skill
    tags: ["weather"],
    body: """
    # Weather Advisor
    ...markdown instructions injected into the LLM prompt...
    """
end
```

Generated functions: `manifest/0` (returns `%Spec{}`), `skill_spec/1`, plus accessors
`Jido.AI.Skill.body/1`, `allowed_tools/1`, `actions/1`.

### 2. Runtime SKILL.md files (agentskills.io format)

YAML frontmatter + markdown body, loaded at runtime:

```elixir
{:ok, spec} = Jido.AI.Skill.Loader.load("priv/skills/code-review/SKILL.md")
Jido.AI.Skill.Registry.register(spec)
```

- `Loader` — parses SKILL.md (`lenient: true` collects warnings as diagnostics instead of failing).
- `Registry` — ETS-backed, `register/1`, `lookup/1` by name, `list/0`; **supports loading whole
  directories at startup**; tracks activation state.
- `Discovery` — scans project/user skill directories; each hit has `name`, `description`,
  `skill_md_path`, `root_dir`, `scope` (`:project` | `:user`), `source_metadata`.
- `Activation` — `activate(name | %Spec{} | module)` → `{:ok, activation_context}` (includes
  `skill_body`); idempotent per session; `activate_many/1` for batches.
- `Prompt` — `Jido.AI.Skill.Prompt.render(skills, header: ...)` renders a
  "You have access to the following skills:" markdown block for system-prompt injection.
- `Resources` — lazy loading of files bundled next to SKILL.md.
- `Spec` struct: `name, description, license, compatibility, metadata, allowed_tools, source,
  body_ref, actions, plugins, vsn, tags, diagnostics`.
- Tooling: `mix jido_ai.skill list|show|validate <paths>`.

### Agent integration surface

- `use Jido.AI.Agent, ..., skills: [...]` — `:skills` option ("Additional skills to attach to the
  agent; TaskSupervisorSkill is auto-included"), `deps/jido_ai/lib/jido_ai/agent.ex:53`.
- `Jido.AI.Agent.tools_from_skills(skill_modules)` — flat-maps each skill's `actions()` (uniq) so
  skill-bundled actions become agent tools. Documented pattern (`agent.ex:945-950`):

```elixir
@skills [MyApp.WeatherSkill, MyApp.LocationSkill]
use Jido.AI.Agent,
  tools: Jido.AI.Agent.tools_from_skills(@skills),
  skills: Enum.map(@skills, & &1.skill_spec(%{}))
```

- Reference example: `deps/jido_ai/examples/lib/skills_demo_agent.ex` +
  `examples/lib/skills/calculator.ex` — module skill defining `allowed_tools` + `actions`, agent
  injects `Jido.AI.Skill.Prompt.render(skills())` appended to its base system prompt.

## How this maps onto ZAQ

ZAQ does **not** use compile-time `use Jido.AI.Agent` modules — agents are runtime-configured:

- `Zaq.Agent.Factory.runtime_config/1` (`lib/zaq/agent/factory.ex:80`) resolves
  `configured_agent.enabled_tool_keys` via `Zaq.Agent.Tools.Registry.resolve_modules/1` and sets
  `system_prompt: configured_agent.job`.
- `Zaq.Agent.ServerManager` starts `Jido.AgentServer` children under
  `Zaq.Agent.AgentServerSupervisor` and re-hydrates tools/MCP at runtime.
- ZAQ tools are already `Jido.Action` modules (`lib/zaq/agent/tools/*`), so they can be bundled
  into skills as `actions:` with zero changes.

### Integration seams (all in the general configured-agent path — no answering-agent special case)

1. **Persistence**: add `enabled_skill_names` (or similar) to `ConfiguredAgent`.
2. **Registration at boot**: load `priv/skills/*/SKILL.md` into `Jido.AI.Skill.Registry` from the
   agent supervisor (Registry supports directory loading at startup); module skills register via
   `manifest/0`.
3. **Factory.runtime_config/1**: resolve enabled skills → merge `spec.actions` into `tools`
   (respect `allowed_tools` gating) and append `Jido.AI.Skill.Prompt.render(skills)` to
   `system_prompt` (flows through existing `ensure_system_prompt/2`).
4. **ServerManager**: optionally pass `skills:` in the `Jido.AgentServer` start opts; skills must
   participate in the restart fingerprint so skill changes trigger lazy restart.
5. **Admin UI**: expose skill toggles like tool toggles (skill list from Registry, not hardcoded —
   same principle as the llm_db rule).

## Open questions for planning

- Runtime activation (`Activation.activate/1` mid-conversation) vs. static prompt injection at
  server start — static injection via Factory is the simpler first step.
- Where SKILL.md files live for on-prem deployments (priv/ vs. a configurable volume).
- Whether `allowed_tools` should intersect with ZAQ's per-agent `enabled_tool_keys` or extend them.
