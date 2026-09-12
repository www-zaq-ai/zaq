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

config = Zaq.Repo.config()

# CI's normal suite still uses its configured administrator connection. Dedicated
# owner/reader roles exercise bootstrap without repurposing that cluster-wide role.
suffix =
  :crypto.hash(:sha256, config[:database]) |> Base.encode16(case: :lower) |> binary_part(0, 16)

owner = "zaq_ci_#{suffix}"
reader = owner <> "_reader"

env = [
  {"PGHOST", config[:hostname] || "localhost"},
  {"PGPORT", to_string(config[:port] || 5432)},
  {"PGUSER", config[:username]},
  {"PGPASSWORD", config[:password] || ""},
  {"PGDATABASE", "postgres"},
  {"ZAQ_OWNER_PASSWORD", Base.encode16(:crypto.strong_rand_bytes(32))},
  {"ZAQ_READER_PASSWORD", Base.encode16(:crypto.strong_rand_bytes(32))}
]

# Running twice also checks operator-script repeatability on both CI engines.
for _ <- 1..2 do
  case System.cmd(
         "psql",
         [
           "-X",
           "--set",
           "ON_ERROR_STOP=1",
           "--set",
           "zaq_database=#{config[:database]}",
           "--set",
           "zaq_owner=#{owner}",
           "--set",
           "zaq_reader=#{reader}",
           "--file",
           script
         ],
         env: env,
         stderr_to_stdout: true
       ) do
    {_output, 0} -> :ok
    {output, status} -> raise "Extension provisioning failed (#{status}): #{output}"
  end
end

IO.puts(
  "Bootstrapped #{engine} database, credentials and extensions in #{config[:database]} (twice)."
)
