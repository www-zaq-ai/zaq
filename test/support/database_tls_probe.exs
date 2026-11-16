# Run by integration/database_tls_test.py against its disposable SSL-only database.
base = Config.Reader.read!("config/config.exs", env: :prod, target: :host)
runtime = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

Config.Reader.merge(base, runtime)
|> Application.put_all_env()

# This database test uses compiled source, without a digested frontend build.
Application.put_env(
  :zaq,
  ZaqWeb.Endpoint,
  Keyword.delete(Application.fetch_env!(:zaq, ZaqWeb.Endpoint), :cache_static_manifest)
)

Application.put_env(:zaq, :skip_super_admin_seed, true)
Application.put_env(:zaq, :license_runtime_key, true)

{:ok, _} = Application.ensure_all_started(:postgrex)

case System.argv() do
  ["connect"] ->
    {:ok, config} = Zaq.Repo.init(:supervisor, Application.fetch_env!(:zaq, Zaq.Repo))
    {:ok, connection} = Postgrex.start_link(config ++ [backoff_type: :stop, sync_connect: true])

    %{rows: [[true]]} =
      Postgrex.query!(connection, "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()", [])

    GenServer.stop(connection)

  ["start"] ->
    Zaq.Release.migrate()
    {:ok, _} = Application.ensure_all_started(:zaq)
    true = is_pid(Process.whereis(Zaq.Supervisor))
    true = is_pid(Process.whereis(ZaqWeb.Endpoint))

    %{rows: [[true]]} =
      Zaq.Repo.query!("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")

    %{rows: [[count]]} = Zaq.Repo.query!("SELECT count(*) FROM schema_migrations")
    true = count > 0
    :ok = Application.stop(:zaq)

  ["migrate"] ->
    Zaq.Release.migrate()
end

IO.puts("TLS probe passed")
