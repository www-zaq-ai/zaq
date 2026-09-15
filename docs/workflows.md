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

| Type        | When to use                             | Version bump |
| ----------- | --------------------------------------- | ------------ |
| `feat:`     | New features                            | MINOR        |
| `fix:`      | Bug fixes                               | PATCH        |
| `docs:`     | Documentation changes                   | —            |
| `style:`    | Code style changes (formatting)         | —            |
| `refactor:` | Code refactoring                        | —            |
| `perf:`     | Performance improvements                | —            |
| `test:`     | Adding or updating tests                | —            |
| `chore:`    | Build process or auxiliary tool changes | —            |

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
5. Validate with `mix precommit` through context-mode with a 15-minute (900,000 ms) execution timeout, followed by applicable E2E tests per `docs/WORKFLOW_AGENT.md`. Do not add a redundant full `mix test` run during validation; the post-review coverage phase generates the full coverage report.

---

## PR Workflow

1. Validate current codebase state before starting with `mix precommit` through context-mode with a 15-minute (900,000 ms) execution timeout; keep logs in context-mode and return only a concise result.
2. Implement the change.
3. Run `mix precommit` through context-mode with the same 15-minute timeout — fix all failures before opening a PR. Never replace it with ad-hoc checks or add a redundant `mix test` run.
4. Open a PR with a clear description referencing the task or Beadwork issue(s).
5. Respond to all review feedback. After all implementation issues in the PR are tackled and review is approved, invoke `coverage-upper` per `docs/WORKFLOW_AGENT.md`, validate and review its changes, then merge when authorized.
6. Update relevant docs if behavior or architecture changed.
7. If the task is planned in Beadwork, keep issue status and notes updated as progress is made.

---

## Planning in Beadwork

For complex or multi-step tasks, check existing Beadwork issues before starting.
If no planning issues exist, create them before writing any code.

- Lightweight planning for small changes can stay in the PR description
- Planned complex work is tracked in Beadwork issues (at least one issue per planned step; split further when needed)
- Prefix each planned issue title with `[{issueId}]`
- Link issue dependencies to encode step order and blockers
- Known shortcuts and deferred work remain tracked in `docs/exec-plans/tech-debt-tracker.md`
