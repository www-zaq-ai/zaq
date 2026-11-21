# :paradedb tests need a ParadeDB-enabled Postgres; the test-paradedb CI job
# re-includes them via `mix test --include paradedb`.
# :real_browser runs explicitly with the pinned agent-browser CLI and Chromium.
# :e2e is the browser suite (test/e2e_pw), run against the real server and a bootstrapped
# database: see docs/e2e-testing.md.
if System.get_env("E2E") == "1" do
  # The app runs for real (E2E=1: the server on :4002, no SQL sandbox), as Playwright Test's
  # webServer did, and the modules share its state.
  Zaq.E2EPw.GlobalSetup.run()
  # Playwright Test's 30 s test timeout, as the journeys had.
  ExUnit.start(exclude: [:integration, :paradedb, :real_browser], timeout: 30_000)
else
  ExUnit.start(exclude: [:integration, :paradedb, :real_browser, :e2e], capture_log: true)
  Ecto.Adapters.SQL.Sandbox.mode(Zaq.Repo, :manual)
  Registry.start_link(keys: :unique, name: Zaq.Engine.Workflows.RunRegistry)
  Logger.put_module_level(Postgrex.Protocol, :none)
  Logger.put_module_level(Task.Supervised, :none)
end
