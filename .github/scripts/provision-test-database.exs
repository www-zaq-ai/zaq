# CI-only DBA step. Run with MIX_ENV=test mix run --no-start <this file> <engine>.
# Resolve the actual configured database (including branch/E2E suffixes), not
# DATABASE_URL, which is only consumed by production runtime configuration.
engine = List.first(System.argv()) || raise "Expected postgres or paradedb"

script =
  case engine do
    "postgres" -> "scripts/setup_postgres_extensions.sql"
    "paradedb" -> "scripts/setup_paradedb_extensions.sql"
    _ -> raise "Expected postgres or paradedb"
  end

Mix.Task.run("ecto.create", ["--quiet"])
config = Zaq.Repo.config()

env = [
  {"PGHOST", config[:hostname] || "localhost"},
  {"PGPORT", to_string(config[:port] || 5432)},
  {"PGUSER", config[:username]},
  {"PGPASSWORD", config[:password] || ""},
  {"PGDATABASE", config[:database]}
]

# Running twice also checks operator-script repeatability on both CI engines.
for _ <- 1..2 do
  case System.cmd("psql", ["-X", "--set", "ON_ERROR_STOP=1", "--file", script],
         env: env,
         stderr_to_stdout: true
       ) do
    {_output, 0} -> :ok
    {output, status} -> raise "Extension provisioning failed (#{status}): #{output}"
  end
end

IO.puts("Provisioned #{engine} extensions in #{config[:database]} (twice).")
