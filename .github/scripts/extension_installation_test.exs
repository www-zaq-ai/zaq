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

  setup do
    engine = List.first(System.argv())
    assert engine in ["postgres", "paradedb"]
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    original = Application.fetch_env!(:zaq, Repo)

    admin_config =
      Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size, :url])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(admin_config)
    name = "zaq_ext_test_#{System.os_time(:microsecond)}"
    password = Base.encode16(:crypto.strong_rand_bytes(24))
    reader = name <> "_reader"

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
        Postgrex.query!(cleanup, "DROP ROLE IF EXISTS #{reader}", [])
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

    %{
      engine: engine,
      admin_config: Keyword.put(admin_config, :database, name),
      maintenance_config: admin_config,
      owner: name,
      password: password,
      reader: reader,
      reader_password: password <> "_reader"
    }
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

    # Some servers allow non-superuser owners to install vector. The contract is
    # that ZAQ leaves provisioning to the DBA, not that the server forbids it.
    assert %{rows: [[false]]} =
             Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector')")

    error = assert_raise Postgrex.Error, fn -> ExtensionChecks.require!(Repo, :pg_search) end
    assert error.postgres.hint =~ "scripts/setup_paradedb_extensions.sql"

    # A coincidentally named type cannot masquerade as pgvector support.
    Repo.query!("CREATE DOMAIN halfvec AS bytea")
    assert_raise Postgrex.Error, fn -> ExtensionChecks.require!(Repo, :vector) end
    Repo.query!("DROP DOMAIN halfvec")

    # Even an empty migration ledger blocks bootstrap. Remove only this test's
    # empty ledger after verifying that the failed migration left no chunks.
    {output, status} = provision(context)
    assert status != 0
    assert output =~ "schema_migrations"
    Repo.query!("DROP TABLE schema_migrations")

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
    assert_reader(context)

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

  test "bootstrap creates a fresh database and rotates both passwords on rerun", context do
    {:ok, admin} = Postgrex.start_link(context.maintenance_config)

    try do
      Postgrex.query!(admin, "DROP DATABASE #{context.owner}", [])
      Postgrex.query!(admin, "DROP ROLE #{context.owner}", [])
      provision_twice(context)
      assert_logins(context)
      previous_hashes = Enum.map([context.owner, context.reader], &password_hash(admin, &1))

      rotated = %{
        context
        | password: "quote'\\secret:owner",
          reader_password: "quote'\\secret:reader"
      }

      provision_twice(rotated)
      assert_logins(rotated)
      rotated_hashes = Enum.map([context.owner, context.reader], &password_hash(admin, &1))

      for {previous, rotated_hash} <- Enum.zip(previous_hashes, rotated_hashes) do
        assert rotated_hash =~ "SCRAM-SHA-256$"
        refute rotated_hash == previous
      end

      Application.put_env(:zaq, Repo, Keyword.put(Repo.config(), :password, rotated.password))
      start_supervised!(Repo)
      Repo.query!("CREATE SCHEMA reporting")
      Repo.query!("CREATE TABLE reporting.items (id integer)")
      Repo.query!("INSERT INTO reporting.items VALUES (1)")
      assert_reader(rotated, "reporting.items")
    after
      GenServer.stop(admin)
    end
  end

  test "unexpected owner and existing migration ledger refuse before changing credentials",
       context do
    start_supervised!(Repo)
    Repo.query!("CREATE TABLE schema_migrations (version bigint)")
    {output, status} = provision(context)
    assert status != 0
    assert output =~ "schema_migrations"

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_roles WHERE rolname = $1", [context.reader])

    Repo.query!("DROP TABLE schema_migrations")
    # The existing database owner is neither this requested owner nor the DBA.
    {output, status} = provision(%{context | owner: context.reader, reader: context.owner})
    assert status != 0
    assert output =~ "owner"

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_roles WHERE rolname = $1", [context.reader])
  end

  test "bootstrap accepts the executing DBA as owner and rejects unsafe roles", context do
    {:ok, admin} = Postgrex.start_link(context.admin_config)

    try do
      Postgrex.query!(
        admin,
        "ALTER DATABASE #{context.owner} OWNER TO #{context.admin_config[:username]}",
        []
      )

      Postgrex.query!(admin, "CREATE ROLE #{context.reader} CREATEDB", [])
      before = password_hash(admin, context.owner)
      {output, status} = provision(%{context | password: "must-not-be-applied"})
      assert status != 0
      assert output =~ "unsafe or shared"
      refute output =~ "must-not-be-applied"
      assert password_hash(admin, context.owner) == before

      Postgrex.query!(admin, "ALTER ROLE #{context.reader} NOCREATEDB", [])
      provision_twice(context)

      assert %{rows: [[owner]]} =
               Postgrex.query!(
                 admin,
                 "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()",
                 []
               )

      assert owner == context.owner
    after
      GenServer.stop(admin)
    end
  end

  test "rerun removes old write ACLs and protects future tables and routines", context do
    provision_twice(context)
    start_supervised!(Repo)
    Repo.query!("CREATE SCHEMA reporting")
    Repo.query!("CREATE TABLE reporting.items (id integer)")
    Repo.query!("GRANT UPDATE (id) ON reporting.items TO #{context.reader}")
    Repo.query!("ALTER DEFAULT PRIVILEGES IN SCHEMA reporting GRANT INSERT ON TABLES TO PUBLIC")

    Repo.query!(
      "CREATE FUNCTION reporting.mutate() RETURNS void LANGUAGE sql SECURITY DEFINER AS 'DELETE FROM reporting.items'"
    )

    Repo.query!("GRANT EXECUTE ON FUNCTION reporting.mutate() TO PUBLIC")
    provision_twice(context)
    Repo.query!("CREATE TABLE reporting.future_items (id integer)")
    assert_reader(context, "reporting.items")
    assert_reader(context, "reporting.future_items")

    assert %{rows: [[false, false, false]]} =
             Repo.query!(
               "SELECT has_column_privilege($1, 'reporting.items', 'id', 'UPDATE'), has_table_privilege($1, 'reporting.future_items', 'INSERT'), has_function_privilege($1, 'reporting.mutate()', 'EXECUTE')",
               [context.reader]
             )
  end

  test "invalid input is rejected without creating the reader", context do
    start_supervised!(Repo)

    for invalid <- [
          %{context | reader: context.owner},
          %{context | password: ""},
          %{context | reader_password: ""},
          %{context | owner: String.duplicate("x", 64)},
          %{context | reader: "pg_reserved"},
          %{context | owner: context.admin_config[:username]}
        ] do
      {output, status} = provision(invalid)
      assert status != 0
      assert output =~ "Invalid bootstrap inputs"
    end

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_roles WHERE rolname = $1", [context.reader])
  end

  test "extension failure rolls back role creation and password rotation", context do
    start_supervised!(Repo)
    Repo.query!("CREATE DOMAIN halfvec AS bytea")
    {:ok, admin} = Postgrex.start_link(context.admin_config)

    try do
      before = password_hash(admin, context.owner)
      {output, status} = provision(%{context | password: "rollback-secret"})
      assert status != 0
      refute output =~ "rollback-secret"
      assert password_hash(admin, context.owner) == before

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM pg_roles WHERE rolname = $1", [context.reader])

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM pg_extension WHERE extname = 'vector'")
    after
      GenServer.stop(admin)
    end
  end

  test "missing psql parameters stop the entire entrypoint", context do
    {output, status} =
      System.cmd("psql", ["-X", "--file", "scripts/setup_#{context.engine}_extensions.sql"],
        env: [
          {"PGHOST", context.admin_config[:hostname] || "localhost"},
          {"PGPORT", to_string(context.admin_config[:port] || 5432)},
          {"PGUSER", context.admin_config[:username]},
          {"PGPASSWORD", context.admin_config[:password] || ""},
          {"PGDATABASE", "postgres"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert output =~ "Missing bootstrap input"
    refute output =~ "CREATE EXTENSION"
    refute output =~ "setup_database_finish.sql"
  end

  test "database and role identifiers are quoted independently of connection syntax", context do
    name = "zaq odd'\\\"#{System.unique_integer([:positive])}"

    quoted = %{
      context
      | owner: name <> " owner",
        reader: name <> " reader",
        admin_config: Keyword.put(context.admin_config, :database, name)
    }

    {:ok, admin} = Postgrex.start_link(context.maintenance_config)

    try do
      provision_twice(quoted)
      assert_logins(quoted)
    after
      for {template, identifier} <- [
            {"DROP DATABASE IF EXISTS %I WITH (FORCE)", name},
            {"DROP ROLE IF EXISTS %I", quoted.owner},
            {"DROP ROLE IF EXISTS %I", quoted.reader}
          ] do
        %{rows: [[sql]]} =
          Postgrex.query!(admin, "SELECT format($1, $2::text)", [template, identifier])

        Postgrex.query!(admin, sql, [])
      end

      GenServer.stop(admin)
    end
  end

  defp password_hash(admin, username) do
    %{rows: [[hash]]} =
      Postgrex.query!(admin, "SELECT rolpassword FROM pg_authid WHERE rolname = $1", [username])

    hash
  end

  defp assert_logins(context) do
    for {username, password} <- [
          {context.owner, context.password},
          {context.reader, context.reader_password}
        ] do
      config = Keyword.merge(context.admin_config, username: username, password: password)
      {:ok, conn} = Postgrex.start_link(config)

      try do
        assert %{rows: [[^username]]} = Postgrex.query!(conn, "SELECT current_user", [])
      after
        GenServer.stop(conn)
      end
    end
  end

  defp assert_reader(context, table \\ "public.chunks") do
    config =
      Keyword.merge(context.admin_config,
        username: context.reader,
        password: context.reader_password
      )

    {:ok, reader} = Postgrex.start_link(config)

    try do
      assert %{rows: [[_]]} = Postgrex.query!(reader, "SELECT count(*) FROM #{table}", [])

      for sql <- [
            "DELETE FROM #{table}",
            "CREATE TABLE public.reader_write (id integer)",
            "CREATE SCHEMA reader_write",
            "CREATE TEMP TABLE reader_write (id integer)"
          ] do
        error = assert_raise Postgrex.Error, fn -> Postgrex.query!(reader, sql, []) end
        assert error.postgres.code == :insufficient_privilege
      end
    after
      GenServer.stop(reader)
    end
  end

  defp provision_twice(context) do
    for _ <- 1..2 do
      {output, status} = provision(context)
      assert status == 0, output
    end
  end

  defp provision(%{engine: engine, admin_config: config} = context) do
    env = [
      {"PGHOST", config[:hostname] || "localhost"},
      {"PGPORT", to_string(config[:port] || 5432)},
      {"PGUSER", config[:username]},
      {"PGPASSWORD", config[:password] || ""},
      {"PGDATABASE", context.maintenance_config[:database]},
      {"ZAQ_OWNER_PASSWORD", context.password},
      {"ZAQ_READER_PASSWORD", context.reader_password}
    ]

    System.cmd(
      "psql",
      [
        "-X",
        "--set",
        "ON_ERROR_STOP=1",
        "--set",
        "zaq_database=#{config[:database]}",
        "--set",
        "zaq_owner=#{context.owner}",
        "--set",
        "zaq_reader=#{context.reader}",
        "--file",
        "scripts/setup_#{engine}_extensions.sql"
      ],
      env: env,
      stderr_to_stdout: true
    )
  end
end
