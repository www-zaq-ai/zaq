# Stack source map

- [Project overview](../../docs/project.md#tech-stack) summarizes the stack; exact runtime pins belong to `.tool-versions`, dependency constraints/Git overrides to `mix.exs`, resolved versions to `mix.lock`. Mix's broad Elixir constraint is not the recommended development pin.
- One OTP app with Phoenix/LiveView, Ecto/PostgreSQL+pgvector, Oban and Jido/ReqLLM integrations. Several Jido dependencies use Git sources/forks; don't replace them with Hex packages or refresh locks incidentally.
- Assets are Mix-managed esbuild/Tailwind (`assets/`); npm/Playwright package is `test/e2e/package.json`, not `assets/package.json`.
- Non-Markdown conversion uses Python scripts fetched under `priv/python/crawler-ingest/` and a root `.venv`; [setup](../../docs/dev-setup.md#python-pipeline) owns prerequisites.
- FTS backend capability varies by deployment. ParadeDB tests are tagged separately; normal test success does not prove ParadeDB support.
- Command side effects and test exclusions: `mem:suggested_commands`; environment/quality owners: `mem:task_completion`.
