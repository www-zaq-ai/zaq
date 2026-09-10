# Standalone, explicitly administrative integration test; never loaded by mix test.
# MIX_ENV=test mix run --no-start .github/scripts/extension_installation_test.exs postgres
# Use paradedb instead to exercise the optional backend. Creates and removes a
# uniquely named database and login; never drops extensions in an existing DB.
ExUnit.start(capture_log: true)

defmodule Zaq.ExtensionInstallationTest do
  use ExUnit.Case, async: false

  alias Zaq.Ingestion.{Chunk, FTSBackend}
  alias Zaq.Repo
  alias Zaq.Repo.ExtensionChecks

  @moduletag timeout: 120_000
  @bm25_version 20_260_418_000_001

  setup_all do
    engine = List.first(System.argv())
    assert engine in ["postgres", "paradedb"]
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    original = Application.fetch_env!(:zaq, Repo)
    admin_config = Repo.config() |> Keyword.drop([:name, :pool, :pool_size, :url])
    {:ok, admin} = Postgrex.start_link(admin_config)
    name = "zaq_ext_test_#{System.os_time(:microsecond)}"
    password = Base.encode16(:crypto.strong_rand_bytes(24))

    Postgrex.query!(
      admin,
      "CREATE ROLE #{name} LOGIN PASSWORD '#{password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS",
      []
    )

    on_exit(fn ->
      Application.put_env(:zaq, Repo, original)
      FTSBackend.reset_cache()
      {:ok, cleanup} = Postgrex.start_link(admin_config)

      try do
        Postgrex.query!(cleanup, "DROP DATABASE IF EXISTS #{name} WITH (FORCE)", [])
        Postgrex.query!(cleanup, "DROP ROLE IF EXISTS #{name}", [])
      after
        GenServer.stop(cleanup)
      end
    end)

    Postgrex.query!(admin, "CREATE DATABASE #{name} OWNER #{name} TEMPLATE template0", [])
    GenServer.stop(admin)

    owner_config =
      admin_config
      |> Keyword.merge(database: name, username: name, password: password, pool_size: 2)

    Application.put_env(:zaq, Repo, owner_config)

    %{engine: engine, admin_config: Keyword.put(admin_config, :database, name)}
  end

  test "provisioning, migrations, rollback and runtime work without superuser", context do
    start_supervised!(Repo)
    start_supervised!(Zaq.Hooks.Supervisor)

    assert %{rows: [[false, false, false, false, false]]} =
             Repo.query!(
               "SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             )

    Code.require_file("priv/repo/migrations/20260301133807_create_chunks.exs")

    error =
      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.up(Repo, 20_260_301_133_807, Zaq.Repo.Migrations.CreateChunks, log: false)
      end

    assert error.postgres.hint =~ "scripts/setup_postgres_extensions.sql"
    assert error.postgres.hint =~ "scripts/setup_paradedb_extensions.sql"
    assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass('public.chunks')")

    # The full replay below compiles migration files again.
    :code.purge(Zaq.Repo.Migrations.CreateChunks)
    :code.delete(Zaq.Repo.Migrations.CreateChunks)

    assert_raise Postgrex.Error, fn -> Chunk.create_table(384) end
    assert_raise Postgrex.Error, fn -> Repo.query!("CREATE EXTENSION vector") end
    error = assert_raise Postgrex.Error, fn -> ExtensionChecks.require!(Repo, :pg_search) end
    assert error.postgres.hint =~ "scripts/setup_paradedb_extensions.sql"

    # A coincidentally named type cannot masquerade as pgvector support.
    Repo.query!("CREATE DOMAIN halfvec AS bytea")
    assert_raise Postgrex.Error, fn -> ExtensionChecks.require!(Repo, :vector) end
    Repo.query!("DROP DOMAIN halfvec")

    provision_twice(context)
    assert :ok = ExtensionChecks.require!(Repo, :vector)

    extension_owners =
      Repo.query!("SELECT extname, extowner FROM pg_extension ORDER BY extname").rows

    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT extowner <> (SELECT oid FROM pg_roles WHERE rolname = current_user) FROM pg_extension WHERE extname = 'vector'"
             )

    # All historical migrations run as the non-superuser database/object owner.
    assert [_ | _] = Ecto.Migrator.run(Repo, "priv/repo/migrations", :up, all: true, log: false)
    assert :ok = Chunk.create_table(384)
    assert :ok = Chunk.reset_table(512)

    expected = if context.engine == "paradedb", do: FTSBackend.ParadeDB, else: FTSBackend.Native
    assert FTSBackend.impl() == expected

    bm25 = Zaq.Repo.Migrations.AddPgTextsearchBm25SimpleIndex
    assert :ok = Ecto.Migrator.down(Repo, @bm25_version, bm25, log: false)

    assert %{rows: [[true]]} =
             Repo.query!("SELECT to_regclass('public.chunks_content_tsvector_idx') IS NOT NULL")

    assert extension_owners ==
             Repo.query!("SELECT extname, extowner FROM pg_extension ORDER BY extname").rows

    assert :ok = Ecto.Migrator.up(Repo, @bm25_version, bm25, log: false)

    if context.engine == "paradedb" do
      assert %{rows: [[true]]} =
               Repo.query!("SELECT to_regclass('public.chunks_bm25_idx') IS NOT NULL")
    else
      assert %{rows: [[true]]} =
               Repo.query!("SELECT to_regclass('public.chunks_content_tsvector_idx') IS NOT NULL")
    end

    # Unexpected index errors cannot be reported as successful migrations.
    assert :ok = Chunk.drop_table()
    Repo.query!("CREATE TABLE chunks (id bigserial PRIMARY KEY)")

    assert_raise Postgrex.Error, fn ->
      Ecto.Migrator.down(Repo, @bm25_version, bm25, log: false)
    end

    assert %{rows: [[1]]} =
             Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [
               @bm25_version
             ])

    Repo.query!("DROP TABLE chunks")

    # Both directions must also support the historical no-chunks state.
    assert :ok = Ecto.Migrator.down(Repo, @bm25_version, bm25, log: false)

    if context.engine == "paradedb" do
      Repo.query!("CREATE TABLE chunks (id bigserial PRIMARY KEY)")

      assert_raise Postgrex.Error, fn ->
        Ecto.Migrator.up(Repo, @bm25_version, bm25, log: false)
      end

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [
                 @bm25_version
               ])

      Repo.query!("DROP TABLE chunks")
    end

    assert :ok = Ecto.Migrator.up(Repo, @bm25_version, bm25, log: false)

    assert extension_owners ==
             Repo.query!("SELECT extname, extowner FROM pg_extension ORDER BY extname").rows
  end

  defp provision_twice(%{engine: engine, admin_config: config}) do
    env = [
      {"PGHOST", config[:hostname] || "localhost"},
      {"PGPORT", to_string(config[:port] || 5432)},
      {"PGUSER", config[:username]},
      {"PGPASSWORD", config[:password] || ""},
      {"PGDATABASE", config[:database]}
    ]

    for _ <- 1..2 do
      {output, status} =
        System.cmd(
          "psql",
          ["-X", "--set", "ON_ERROR_STOP=1", "--file", "scripts/setup_#{engine}_extensions.sql"],
          env: env,
          stderr_to_stdout: true
        )

      assert status == 0, output
    end
  end
end
