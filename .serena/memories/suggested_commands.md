# Command entry points

- [Dev setup](../../docs/dev-setup.md) owns setup/server/Python/browser instructions. `mix.exs` defines aliases; `test/e2e/package.json` defines browser commands. [Workflow](../../docs/WORKFLOW_AGENT.md#phase-4--validate) owns when checks run, not this memory.
- Main commands: `mix setup`, `mix phx.server`, targeted `mix test test/path_test.exs`, `mix q`, final `mix precommit`. `mix q` formats and may unlock unused dependencies; it does not run tests. Do not run it as a read-only observation.
- `mix setup.branch [source_db]` clones a source DB; `mix ecto.reset` drops a DB. Neither is a harmless validation step.
- Browser full suite: `npm run test` in `test/e2e/`; root `mix e2e` selects journeys. `mix storybook` runs Storybook tests, not a development server.
- Browser bootstrap uses its own test DB/build path. `config/test.exs` derives DB names from branch/E2E/partition; don't assume worktrees share a test database.
- `test/test_helper.exs` excludes integration, paradedb and real_browser tags by default. Include them explicitly only with their prerequisites.
- `mix coverup` reads an existing coverage report; it does not generate one. Follow the coverage workflow, never infer freshness from this command.
- No special Darwin command substitutions established; avoid GNU-only assumptions. Validation timing and blockers: `mem:task_completion`.
