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
5. Read and follow the [validation lifecycle](WORKFLOW_AGENT.md#phase-4--validate), including issue checks, E2E and final approval gates.

---

## PR Workflow

1. Follow [workflow orientation](WORKFLOW_AGENT.md#phase-1--orient) before starting.
2. Implement the change.
3. Complete the [issue validation checks](WORKFLOW_AGENT.md#unit-validation).
4. Open a PR with a clear description referencing the task or Beadwork issue(s).
5. Respond to review feedback, then follow [coverage and final approval](WORKFLOW_AGENT.md#phase-6--coverage-and-merge); merge only when approved and authorized.
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

---

## Releases

Releases are automated through a release PR gate using [release-please](https://github.com/googleapis/release-please-action). The authoritative automation is [`.github/workflows/release.yml`](../.github/workflows/release.yml), with [release configuration](../release-please-config.json) and the [version manifest](../.release-please-manifest.json).

- Feature and hotfix PRs target `main` and use Conventional Commit titles.
- Merges update or create a release PR rather than immediately publishing a release.
- Merging the release PR updates the version in `mix.exs`, creates the tag, and publishes the GitHub Release.
- The release workflow builds container images and publishes documentation. See [published image tags](operations/deployment.md#published-container-images).

### Maintainer setup

GitHub Actions must be allowed to create release pull requests. The workflow uses `RELEASE_PLEASE_TOKEN` when supplied, otherwise `GITHUB_TOKEN`; provision appropriate repository/workflow permissions for a dedicated token if needed. Keep tokens in repository secrets, never tracked files.

For a new fork or release stream, align the release manifest, `mix.exs` version, and any baseline tag before enabling releases. The old `v0.1.0` bootstrap instruction is not an instruction to retag this existing repository. Tag creation and publishing are maintainer actions, not application installation steps.
