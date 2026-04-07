# Code Quality

## Separation of Concerns & Architecture Boundaries

- Keep domain and business rules in `lib/zaq/` contexts/domain modules.
- LiveViews, controllers, plugs, and workers orchestrate and delegate — never own business logic.
- BO modules in `lib/zaq_web/` must not access persistence or integrations directly — call context APIs and use `NodeRouter.call/4` for cross-service boundaries.
- Treat context internals as private implementation details. Cross-context calls use public context functions, not internal helpers.
- Keep module responsibilities cohesive. If a module owns unrelated concerns (querying + formatting + transport), split it.
- For bridge/adapter domains, enforce: bridge orchestrates, adapter implements transport mechanics.
- Reject changes where bridges define adapter listener child specs directly; bridge must delegate runtime spec construction to adapter APIs.
- Reject adapter-specific sink callback names in bridge APIs; use standardized `from_listener/3` callback naming.

---

## DRY & Pattern Reuse

- Reuse existing context APIs, query helpers, changeset patterns, and UI components before introducing new abstractions.
- Apply a rule-of-three for extraction: duplicate twice if needed, extract shared abstractions once the pattern is stable.
- Prefer extending established project patterns instead of creating competing variants without a strong reason.
- Avoid catch-all utility modules. Helpers should be domain-scoped and intent-revealing.
- Prefer shared utility packages over hand-rolled helpers to keep invariants centralized.

---

## Data Access & Side-Effect Boundaries

- Keep Ecto queries and persistence logic in context/domain modules — never in LiveViews, components, or templates.
- Keep HTTP/external calls in adapter/integration modules; depend on behaviours at domain boundaries.
- Preload associations when needed by rendering layers to prevent N+1 queries.
- Make Oban workers and external side-effect operations idempotent so retries are safe.
- Do not probe data shapes speculatively — validate at boundaries or rely on typed SDKs.

---

## Technical Debt Controls

- Any temporary shortcut must include a `TODO` with a linked issue and clear removal condition.
- Remove dead code and stale branches when replacing behavior — do not keep inactive paths "just in case".
- If a change intentionally diverges from established patterns, document the rationale in the PR description.
- Track all known debt in `docs/exec-plans/tech-debt-tracker.md`.

---

## Linting & Enforcement

- Run `mix precommit` before every commit — never replace it with ad-hoc checks.
- `mix credo --strict` for code standards on bugfixes.
- Custom linters enforce: structured logging, naming conventions for schemas and types, file size limits, and platform-specific reliability requirements.
- Linter error messages are written to inject remediation instructions into agent context.
- Architectural layer rules (Types → Config → Repo → Service → Runtime → UI) are enforced mechanically via structural tests.

---

## Quality Grades

Domain quality grades are tracked in `docs/QUALITY_SCORE.md`. Consult it to understand
the current state of each domain before making changes, and update it when the state changes.
