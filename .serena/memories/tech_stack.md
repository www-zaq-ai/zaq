# Runtime and build stack

- `.tool-versions` pins Elixir **1.19.5**, Erlang **28.5.0.2**. `mix.exs` declares broader `elixir: "~> 1.15"`; use tool pins for the development environment, not that lower constraint as the recommended runtime.
- `mix.exs` current constraints: Phoenix `~> 1.8.3`, LiveView `~> 1.2`, Ecto SQL `~> 3.13`, Oban `~> 2.20.3`, pgvector `~> 0.3.1`, Req `~> 0.6`. Consult `mix.lock` for exact resolved versions. Some Jido ecosystem dependencies use Git branches/forks: do not casually replace with Hex versions or update locks.
- PostgreSQL 16+ with pgvector >= 0.7.0/halfvec per setup docs. Hybrid search has pluggable FTS backend under `lib/zaq/ingestion/fts_backend/`; ParadeDB-specific tests are separately tagged.
- Agent/workflow ecosystem: Jido, Jido.Action, Jido AI, ReqLLM, LLMDB, Jido MCP, Jido Runic; connector/chat integrations behind Channels bridges. Customer/deployment-configured LLM providers, not fixed hosted endpoints.
- Assets compiled through Mix-managed esbuild/Tailwind, source `assets/js/` and `assets/css/`. Phoenix Storybook supplies component contracts. Node >=20 for Playwright; npm package lives in `test/e2e/`, not `assets/`.
- Python >=3.10 plus root `.venv` for non-Markdown conversion; fetched scripts/dependencies under `priv/python/crawler-ingest/`, coordinated by `lib/zaq/ingestion/python/`.
- Tests: ExUnit, Ecto SQL Sandbox, Mox, StreamData; Playwright for E2E. Quality: Credo, hooks verification, ExDoc warnings, compiler warnings; ExCoveralls for coverage. Dialyxir is installed but is not part of the current `mix q`/`mix precommit` aliases.
- Darwin development shell: no project-specific alternative syntax established for ordinary Unix commands. Prefer configured tools over assuming GNU-only command flags.
