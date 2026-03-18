defmodule Zaq.License.LicensePostLoader do
  @moduledoc """
  GenServer that handles post-license-load steps.

  After a .zaq-license is loaded into the BEAM, this GenServer:
    1. Receives migration file contents extracted from the license package
    2. Writes them to a temp directory
    3. Runs them against Zaq.Repo via Ecto.Migrator

  Migration files are plain .exs files bundled unencrypted in migrations/
  inside the .zaq-license package. Runtime modules remain encrypted.

  ## Usage

  Called by `Zaq.License.Loader` after `FeatureStore.store/2`:

      Zaq.License.LicensePostLoader.notify(license_data, migration_files)

  Where migration_files is a list of {filename, content} tuples.
  """

  use GenServer

  alias Zaq.License.Loader

  require Logger

  @doc """
  Notifies the GenServer that a license was loaded.
  migration_files and view_files are lists of {filename, binary_content} tuples.
  """
  def notify(license_data, migration_files \\ [], view_files \\ []) do
    GenServer.cast(__MODULE__, {:license_loaded, license_data, migration_files, view_files})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    send(self(), :load_startup_license)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_startup_license, state) do
    dir = Application.app_dir(:zaq, "priv/licenses")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".zaq-license"))
        |> Enum.each(&load_license_file(Path.join(dir, &1)))

      {:error, _} ->
        Logger.debug("[LicensePostLoader] No licenses directory at #{dir}, skipping.")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:license_loaded, license_data, migration_files, view_files}, state) do
    license_key = Map.get(license_data, "license_key", "unknown")
    Logger.info("[LicensePostLoader] Running post-load steps for license: #{license_key}")

    run_migrations(migration_files)
    compile_views(view_files)

    # Broadcast that license has been updated (migrations + views complete)
    Phoenix.PubSub.broadcast(Zaq.PubSub, "license:updated", :license_updated)
    Logger.debug("[LicensePostLoader] Broadcast license:updated event")

    {:noreply, state}
  end

  # --- Private ---

  defp load_license_file(path) do
    case Loader.load(path) do
      {:ok, _} ->
        Logger.info("[LicensePostLoader] Loaded license from #{path}")

      {:error, reason} ->
        Logger.warning("[LicensePostLoader] Failed to load #{path}: #{inspect(reason)}")
    end
  end

  defp compile_views([]) do
    Logger.debug("[LicensePostLoader] No view files in license, skipping.")
  end

  defp compile_views(view_files) do
    Logger.info("[LicensePostLoader] Compiling #{length(view_files)} view file(s)...")

    tmp_dir = Path.join(System.tmp_dir!(), "zaq_views_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      Enum.each(view_files, fn {filename, content} ->
        File.write!(Path.join(tmp_dir, filename), content)
      end)

      view_files
      |> Enum.filter(fn {filename, _} -> String.ends_with?(filename, ".ex") end)
      |> Enum.each(fn {filename, _} ->
        path = Path.join(tmp_dir, filename)
        Code.compile_file(path)
        Logger.info("[LicensePostLoader] Compiled view: #{filename}")
      end)
    rescue
      e ->
        Logger.error("[LicensePostLoader] View compilation failed: #{Exception.message(e)}")
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp run_migrations([]) do
    Logger.debug("[LicensePostLoader] No migration files in license, skipping.")
  end

  defp run_migrations(migration_files) do
    Logger.info("[LicensePostLoader] Found #{length(migration_files)} migration(s), running...")

    tmp_dir = Path.join(System.tmp_dir!(), "zaq_migrations_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      # Write migration files to tmp dir
      Enum.each(migration_files, fn {filename, content} ->
        File.write!(Path.join(tmp_dir, filename), content)
      end)

      # Run migrations via Ecto.Migrator
      Ecto.Migrator.run(Zaq.Repo, tmp_dir, :up, all: true)

      Logger.info("[LicensePostLoader] Migrations completed successfully.")
    rescue
      e ->
        Logger.error("[LicensePostLoader] Migrations failed: #{Exception.message(e)}")
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
