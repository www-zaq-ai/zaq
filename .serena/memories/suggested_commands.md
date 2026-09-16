# Project commands

Source of truth: `mix.exs`, `docs/dev-setup.md`, `test/e2e/package.json`; validation timing in `mem:task_completion`.

- Orient: `bw prime`; inspect existing issues before complex work. Follow `docs/agent-tools.md` for tool routing. Confirm treatment of existing worktree changes; do not auto-stash/reset.
- Bootstrap: `mix setup` = deps.get, ecto.setup (create+migrate), assets setup/build, Python fetch. `mix phx.server` serves development BO at `http://localhost:4000/bo`.
- Optional branch DB clone: `mix setup.branch [source_db]`, default source `zaq_main`; performs `db.copy` as part of setup. Not equivalent to empty DB setup; inspect before use. `mix ecto.reset` drops the database; never run as a harmless check.
- Python: `python3 -m venv .venv`, activate `.venv/bin/activate`, `pip install -r priv/python/crawler-ingest/requirements.txt`. Refresh via `mix zaq.python.fetch`; explicit pin via `mix zaq.python.fetch --commit <sha>`.
- Tests: `mix test test/path_test.exs` (or `:line`), `mix test --failed`, `mix test`. Test alias creates/migrates DB first. Default ExUnit excludes `:integration`, `:paradedb`, `:real_browser` (`test/test_helper.exs`); include explicitly only with matching prerequisites, e.g. `mix test --include paradedb`.
- `mix q`: formats, verifies hooks, strict Credo, unlocks unused dependencies, ExDoc warnings-as-errors, compiler warnings-as-errors. It **can modify files/lockfile** and does **not** run tests. `mix qf` checks formatting and skips unused-dep unlock; it is not a substitute for the required issue gate.
- Final gate: `mix precommit` (test env): formatting check, strict Credo, warnings-as-errors compile, stale tests.
- Coverage: `mix coveralls.json`, then only on success `mix coverup [threshold] [limit]`. coverup reads `cover/excoveralls.json`, compares changed lib files against main/worktree/index, and depends on shell tools including jq; it does not generate coverage.
- Browser setup: npm dependencies and `npx playwright install` in `test/e2e/`. Run `npm run test` there for bootstrap + full suite; `npm run test:journeys` for journeys; `npm run test:headed` for visible browser. Root aliases: `mix e2e` selects journeys, `mix storybook` selects Storybook (not a dev-server command).
- E2E uses `PORT=4002 MIX_ENV=test E2E=1 MIX_BUILD_PATH=_build/test-e2e`; package scripts bootstrap assets/DB/fixtures. Do not accidentally run browser tests against a normal dev DB.
- Assets: `mix assets.setup`, `mix assets.build`, `mix assets.deploy` (minification + phx.digest).
