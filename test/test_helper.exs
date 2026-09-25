# :paradedb tests need a ParadeDB-enabled Postgres; the test-paradedb CI job
# re-includes them via `mix test --include paradedb`.
# :real_browser runs explicitly with the pinned agent-browser CLI and Chromium.
# :real_python runs explicitly with the fetched crawler and provisioned CPython 3.13.
ExUnit.start(exclude: [:integration, :paradedb, :real_browser, :real_python], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Registry.start_link(keys: :unique, name: Zaq.Engine.Workflows.RunRegistry)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)
