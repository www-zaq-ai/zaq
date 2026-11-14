# :paradedb tests need a ParadeDB-enabled Postgres; the test-paradedb CI job
# re-includes them via `mix test --include paradedb`.
# :real_browser runs explicitly with the pinned agent-browser CLI and Chromium.
# :commercial_gateway is optional real-Rust interoperability, never a CI prerequisite.
# :protobuf runs explicitly with the pinned protoc compiler.
ExUnit.start(
  exclude: [:integration, :paradedb, :real_browser, :commercial_gateway, :protobuf],
  capture_log: true
)

Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
Registry.start_link(keys: :unique, name: Zaq.Engine.Workflows.RunRegistry)
Logger.put_module_level(Postgrex.Protocol, :none)
Logger.put_module_level(Task.Supervised, :none)
