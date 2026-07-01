# Project Claude skills (Zaq)

Skills in this directory extend the agent for Zaq-specific workflows. **BO UI:** read [`DESIGN.md`](../../DESIGN.md) first.

| Skill | Path | Use when |
| --- | --- | --- |
| **design** | [design/SKILL.md](design/SKILL.md) | New BO UI — entry point; routes to other skills |
| **design-migrate** | [design-migrate/SKILL.md](design-migrate/SKILL.md) | Migrating UI to `--zaq-*` tokens; Figma-led or path audit |
| **extract** | [extract/SKILL.md](extract/SKILL.md) | Copy inline UI slices into `DesignSystem.*` modules |
| **replace** | [replace/SKILL.md](replace/SKILL.md) | Wire existing components into LiveViews (after extract + migrate) |
| **run** | [run/SKILL.md](run/SKILL.md) | Start Phoenix + Storybook locally |
| **ux-design** | [ux-design/SKILL.md](ux-design/SKILL.md) | Translate a PRD into flows, wireframes, and component mapping |
| **prototype** | [prototype/SKILL.md](prototype/SKILL.md) | Stage the UX plan on real BO routes at `/bo/{slug}` with fixtures |
| **iterate** | [iterate/SKILL.md](iterate/SKILL.md) | Apply human feedback — update PRD, UX plan, and prototype |

### Discovery agents (used by `/brief` / pm-senior)

| Agent | Path | Use when |
| --- | --- | --- |
| **design-critic** | [../agents/design-critic.md](../agents/design-critic.md) | Challenge UX/friction/coherence on Brief v1 — not wireframes |
| **tech-critic** | global `.claude/agents/tech-critic.md` | Complexity, edge cases, code-based feasibility |
| **data-critic** | global `.claude/agents/data-critic.md` | Measurability, events, baseline |

**Typical feature discovery workflow:** `/brief` (pm-senior + critics) → PRD → `ux-design` → `prototype` → human review → `iterate` (repeat until approved) → `design`

**Typical BO design-system workflow (human confirmation at each step):** `extract` → `design-migrate` → `replace`

Reference material for **ux-design** lives in [ux-design/output-template.md](ux-design/output-template.md) and [ux-design/examples.md](ux-design/examples.md).
