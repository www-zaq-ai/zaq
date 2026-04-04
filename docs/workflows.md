# Workflows

## Git Branching Strategy

### Branch Hierarchy
1. `feature/` branches → Code review + Unit tests → merge into `main`
2. `hotfix/` branches → Urgent post-release fixes → merge into `main`
3. `main` branch → Stable source of truth → release PR/tag → Docker image + docs update

### Branch Naming
- `feature/description`
- `feature/issue-123-description`
- `hotfix/description`

### Current Branch Check
Before creating any PR, verify:
- Is this a feature/fix? → Use `feature/*` and target `main`
- Is this an urgent post-release patch? → Use `hotfix/*` and target `main`
- Is this a versioned release? → Managed by `release-please` from `main`

### AI Agent Rules
- **NEVER** push directly to `main` — all changes must go through a Pull Request
- **ALWAYS** target `main` for feature and hotfix PRs

---

## Semantic Versioning for Commits and PR Names

All commits and PR titles MUST follow [Conventional Commits](https://www.conventionalcommits.org/).

**Format:** `<type>(<scope>): <description>`

| Type | When to use | Version bump |
|---|---|---|
| `feat:` | New features | MINOR |
| `fix:` | Bug fixes | PATCH |
| `docs:` | Documentation changes | — |
| `style:` | Code style changes (formatting) | — |
| `refactor:` | Code refactoring | — |
| `perf:` | Performance improvements | — |
| `test:` | Adding or updating tests | — |
| `chore:` | Build process or auxiliary tool changes | — |

**Examples:**
```
feat(auth): add OAuth2 login support
fix(api): resolve null pointer in user endpoint
docs(readme): update installation instructions
```

**Breaking changes** — add `!` after the type or include `BREAKING CHANGE:` in the footer:
```
feat(api)!: remove deprecated v1 endpoints
```

---

## Bugfix Workflow (MANDATORY)

Follow this for every bug — no exceptions:

1. Write or update an automated test that reproduces the bug.
2. Fix the code and confirm the new/updated test passes.
3. Iterate on the fix until the reproducing test passes reliably.
4. Check code standards with `mix credo --strict`.
5. Confirm no regression by running the full test suite:
   - Unit tests first
   - E2E tests second

---

## PR Workflow

1. Validate current codebase state before starting (`mix test`, `mix precommit`).
2. Implement the change.
3. Run `mix precommit` — fix all failures before opening a PR. Never replace it with ad-hoc checks.
4. Open a PR with a clear description referencing the task or exec plan.
5. Respond to all review feedback before merging.
6. Update relevant docs if behavior or architecture changed.
7. If the task has an active exec plan in `docs/exec-plans/active/`, update its progress log.

---

## Execution Plans

For complex or multi-step tasks, check `docs/exec-plans/active/` before starting.
If no plan exists for a complex task, create one first before writing any code.

- Lightweight plans for small changes (inline in PR description)
- Full exec plans for complex work — checked into `docs/exec-plans/active/` with progress and decision logs
- Completed plans move to `docs/exec-plans/completed/`
- Known shortcuts and deferred work tracked in `docs/exec-plans/tech-debt-tracker.md`