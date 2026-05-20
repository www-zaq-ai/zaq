Analyze the staged and unstaged changes, then output a single conventional commit message line.

## Steps

1. Run `git diff --cached --stat` to see staged files and change counts.
2. Run `git diff --stat` to see unstaged changes (for context, not included in commit).
3. Run `git diff --cached` to read the actual diff content.
4. Determine **type** from the diff:
   - `feat` — new behavior, new module, new endpoint, new field
   - `fix` — bug fix, incorrect logic corrected
   - `refactor` — restructure without behavior change
   - `test` — adding or fixing tests only
   - `docs` — documentation only
   - `chore` — config, deps, tooling, CI
   - `perf` — performance improvement
5. Determine **scope** from the changed file paths (use the most specific applicable scope):

   | Path pattern                          | Scope          |
   | ------------------------------------- | -------------- |
   | `lib/zaq/workflows/`                  | `workflows`    |
   | `lib/zaq/engine/`                     | `engine`       |
   | `lib/zaq/agent/`                      | `agent`        |
   | `lib/zaq/channels/`                   | `channels`     |
   | `lib/zaq/ingestion/`                  | `ingestion`    |
   | `lib/zaq/license/`                    | `license`      |
   | `lib/zaq_web/live/`                   | `live`         |
   | `lib/zaq_web/`                        | `web`          |
   | `priv/repo/migrations/`               | `migrations`   |
   | `test/`                               | same as source |
   | `docs/`                               | `docs`         |
   | `config/` or `.github/` or `mix.exs` | `chore`        |

   If changes span multiple scopes, pick the dominant one.

6. Write a short, lowercase, imperative description (max 72 chars total).
7. If the change is a breaking API change, append `!` after the scope: `feat(workflows)!`.

## Output

Print **only** the commit message line — nothing else. No explanation, no alternatives, no markdown.

Example outputs:
```
feat(workflows): add conditional edge routing with condition validation
fix(engine): prevent duplicate notification dispatch on retry
refactor(agent): extract provider URL logic into ProviderSpec
test(ingestion): add property tests for chunk boundary invariants
docs(workflows): update trigger model and module table
```
