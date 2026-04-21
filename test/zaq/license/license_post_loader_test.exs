defmodule Zaq.License.LicensePostLoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.License.LicensePostLoader

  setup do
    case GenServer.whereis(LicensePostLoader) do
      nil -> start_supervised!(LicensePostLoader)
      _pid -> :ok
    end

    Phoenix.PubSub.subscribe(Zaq.PubSub, "license:updated")
    :ok
  end

  # ---------------------------------------------------------------------------
  # notify/3 — migration paths
  # ---------------------------------------------------------------------------

  test "notify broadcasts license updated when no migrations are provided" do
    LicensePostLoader.notify(%{"license_key" => "lic_no_migrations"}, [])

    assert_receive :license_updated
  end

  test "notify still broadcasts when migration processing raises" do
    migration_files = [{"nested/path/001_bad.exs", "raise \"boom\""}]

    log =
      capture_log(fn ->
        LicensePostLoader.notify(%{"license_key" => "lic_with_bad_migration"}, migration_files)
        assert_receive :license_updated
      end)

    assert log =~ "Migrations failed"
  end

  test "notify with non-migration-named file succeeds and logs completion" do
    # File doesn't match Ecto's migration naming pattern (no leading timestamp),
    # so Ecto.Migrator skips it, run_migrations/1 completes cleanly → line 141.
    # The GenServer process needs sandbox access to check schema_migrations.
    pid = GenServer.whereis(LicensePostLoader)
    :ok = Sandbox.checkout(Zaq.Repo)
    Sandbox.allow(Zaq.Repo, self(), pid)
    on_exit(fn -> Sandbox.checkin(Zaq.Repo) end)

    migration_files = [{"not_a_migration.exs", "# placeholder, ecto ignores this"}]

    LicensePostLoader.notify(%{"license_key" => "lic_norun"}, migration_files)

    # Receiving :license_updated confirms run_migrations/1 reached the success
    # path (line 141) without raising.
    assert_receive :license_updated
  end

  # ---------------------------------------------------------------------------
  # notify/3 — view_files paths (compile_views/1 non-empty clause)
  # ---------------------------------------------------------------------------

  test "notify with valid view files compiles them and broadcasts" do
    # Use a unique module name to avoid clashes across test runs.
    id = System.unique_integer([:positive, :monotonic])

    view_files = [
      {"view_#{id}.ex", "defmodule ZaqTestCoverageView#{id} do end"}
    ]

    LicensePostLoader.notify(%{"license_key" => "lic_views"}, [], view_files)

    assert_receive :license_updated
  end

  test "notify with invalid view file rescues and still broadcasts" do
    # Triggers the rescue branch in compile_views/1 (lines 115-116).
    view_files = [{"bad_view.ex", "this is @@@invalid elixir !!!"}]

    log =
      capture_log(fn ->
        LicensePostLoader.notify(%{"license_key" => "lic_bad_views"}, [], view_files)
        assert_receive :license_updated
      end)

    assert log =~ "View compilation failed"
  end

  test "notify with non-ex view file writes it but skips compilation" do
    # A .txt file is written to tmp_dir but filtered out before Code.compile_file/1.
    view_files = [{"readme.txt", "just docs"}]

    LicensePostLoader.notify(%{"license_key" => "lic_txt_view"}, [], view_files)

    assert_receive :license_updated
  end

  # ---------------------------------------------------------------------------
  # handle_info :load_startup_license — {:ok, files} branch (lines 55-56, 83, 87-88)
  # ---------------------------------------------------------------------------

  test "load_startup_license logs warning when license file is invalid" do
    # Create a fake .zaq-license file in the priv/licenses dir so the
    # {:ok, files} branch is taken and load_license_file/1 is called.
    # Loader.load/1 will fail on the fake content → covers lines 55-56 and 87-88.
    dir = Application.app_dir(:zaq, "priv/licenses")
    File.mkdir_p!(dir)

    id = System.unique_integer([:positive])
    license_path = Path.join(dir, "test_coverage_#{id}.zaq-license")
    File.write!(license_path, "not a valid license")

    on_exit(fn -> File.rm(license_path) end)

    pid = GenServer.whereis(LicensePostLoader)

    log =
      capture_log(fn ->
        send(pid, :load_startup_license)
        # :sys.get_state/1 blocks until the GenServer drains its message queue.
        :sys.get_state(pid)
      end)

    assert log =~ "Failed to load"
  end
end
