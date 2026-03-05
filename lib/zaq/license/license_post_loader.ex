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

  require Logger

  @doc """
  Notifies the GenServer that a license was loaded.
  migration_files is a list of {filename, binary_content} tuples.
  """
  def notify(license_data, migration_files \\ []) do
    GenServer.cast(__MODULE__, {:license_loaded, license_data, migration_files})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:license_loaded, license_data, migration_files}, state) do
    license_key = Map.get(license_data, "license_key", "unknown")
    Logger.info("[LicensePostLoader] Running post-load steps for license: #{license_key}")

    run_migrations(migration_files)

    {:noreply, state}
  end

  # --- Private ---

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
