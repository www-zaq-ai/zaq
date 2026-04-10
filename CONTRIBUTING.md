# Contributing to ZAQ

Thank you for your interest in contributing to ZAQ. This guide covers everything you need to get started.

## Prerequisites

Before contributing, make sure you have a working local setup. See the **Running ZAQ — Local (Mix)** section in the [README](README.md) for full instructions.

TL;DR:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
mix setup
mix phx.server
```

## Branching

| Branch type | Naming | Targets |
|---|---|---|
| New features / fixes | `feature/description` or `feature/issue-123-description` | `main` |
| Urgent post-release patches | `hotfix/description` | `main` |

Never push directly to `main`. All changes go through a Pull Request.

## Commit Messages

All commits and PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/).

**Format:** `<type>(<scope>): <description>`

| Type | When to use |
|---|---|
| `feat:` | New user-facing feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `refactor:` | Code restructuring, no behavior change |
| `perf:` | Performance improvement |
| `test:` | Adding or updating tests |
| `chore:` | Tooling, build, deps |

**Examples:**
```
feat(auth): add OAuth2 login support
fix(api): resolve null pointer in user endpoint
docs(readme): update installation instructions
```

**Breaking changes** — append `!` after the type:
```
feat(api)!: remove deprecated v1 endpoints
```

## Making a Change

1. Create your branch from `main`.
2. Write or update tests that cover your change.
3. Implement the change.
4. Run the full quality check before committing:
   ```bash
   mix precommit
   ```
   Fix all failures — do not skip or replace this step.
5. Open a Pull Request targeting `main` with a clear description of what changed and why.
6. Respond to all review feedback before merging.
7. Update relevant docs if behavior or architecture changed.

## Bug Fixes

For bug fixes specifically:

1. Write a test that reproduces the bug first.
2. Fix the code until the test passes.
3. Run `mix credo --strict` in addition to `mix precommit`.

## Architecture Boundaries

A few rules that reviewers will check:

- Business logic lives in `lib/zaq/` contexts — not in LiveViews, controllers, or workers.
- Back Office (`lib/zaq_web/`) must not query the DB or call integrations directly. Use context APIs and `NodeRouter.call/4` for cross-service calls.
- Keep Ecto queries in context/domain modules, never in templates or components.

## Code Quality

- `mix precommit` runs formatter, Credo, and custom linters. Green = ready to commit.
- Any temporary shortcut must include a `TODO` with a linked issue and a clear removal condition.
- Remove dead code — don't leave inactive paths "just in case".
- If your change intentionally diverges from established patterns, explain why in the PR description.

## Releases

Releases are managed automatically by [release-please](https://github.com/googleapis/release-please-action). Merging your PR into `main` updates the release PR. You don't need to bump versions manually.

## Questions

Open a [GitHub Issue](https://github.com/www-zaq-ai/zaq/issues) if something is unclear or you run into a problem during setup.
