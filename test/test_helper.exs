# :paradedb tests need a ParadeDB-enabled Postgres; the test-paradedb CI job
# re-includes them via `mix test --only paradedb`.
ExUnit.start(exclude: [:integration, :paradedb], capture_log: true)
Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)
