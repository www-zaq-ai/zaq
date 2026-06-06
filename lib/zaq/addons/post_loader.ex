defmodule Zaq.Addons.PostLoader do
  @moduledoc """
  GenServer that handles post-add-on-load steps.

  After a .zaq-license is loaded into the BEAM, this GenServer:
    1. Receives migration file contents extracted from the add-on package
    2. Writes them to a temp directory
    3. Runs them against Zaq.Repo via Ecto.Migrator

  Migration files are plain .exs files bundled unencrypted in migrations/
  inside the .zaq-license package. Runtime modules remain encrypted.

  ## Usage

  Called by `Zaq.Addons.PackageLoader` after `FeatureStore.store/2`:

      Zaq.Addons.PostLoader.notify(addon_data, migration_files)

  Where migration_files is a list of {filename, content} tuples.
  """

  use GenServer

  alias Zaq.Addons.PackageLoader

  require Logger

  @doc """
  Notifies the GenServer that an add-on package was loaded.
  migration_files and view_files are lists of {filename, binary_content} tuples.
  """
  def notify(addon_data, migration_files \\ [], view_files \\ []) do
    GenServer.cast(__MODULE__, {:addon_loaded, addon_data, migration_files, view_files})
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    send(self(), :load_startup_addons)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:load_startup_addons, state) do
    dir = Application.app_dir(:zaq, "priv/licenses")

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".zaq-license"))
        |> Enum.each(&load_addon_package(Path.join(dir, &1)))

      {:error, _} ->
        Logger.debug("[PostLoader] No licenses directory at #{dir}, skipping.")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:addon_loaded, addon_data, migration_files, view_files}, state) do
    license_key = Map.get(addon_data, "license_key", "unknown")
    Logger.info("[PostLoader] Running post-load steps for add-on package: #{license_key}")

    run_migrations(migration_files)
    compile_views(view_files)

    # Broadcast after add-on migrations and views are complete.
    Phoenix.PubSub.broadcast(Zaq.PubSub, "addons:updated", :addons_updated)
    Logger.debug("[PostLoader] Broadcast addons:updated event")

    {:noreply, state}
  end

  # --- Private ---

  defp load_addon_package(path) do
    case PackageLoader.load(path) do
      {:ok, _} ->
        Logger.info("[PostLoader] Loaded add-on package from #{path}")

      {:error, reason} ->
        Logger.warning("[PostLoader] Failed to load #{path}: #{inspect(reason)}")
    end
  end

  defp compile_views([]) do
    Logger.debug("[PostLoader] No view files in add-on package, skipping.")
  end

  defp compile_views(view_files) do
    Logger.info("[PostLoader] Compiling #{length(view_files)} view file(s)...")

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
        Logger.info("[PostLoader] Compiled view: #{filename}")
      end)
    rescue
      e ->
        Logger.error("[PostLoader] View compilation failed: #{Exception.message(e)}")
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp run_migrations([]) do
    Logger.debug("[PostLoader] No migration files in add-on package, skipping.")
  end

  defp run_migrations(migration_files) do
    Logger.info("[PostLoader] Found #{length(migration_files)} migration(s), running...")

    tmp_dir = Path.join(System.tmp_dir!(), "zaq_migrations_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    try do
      # Write migration files to tmp dir
      Enum.each(migration_files, fn {filename, content} ->
        File.write!(Path.join(tmp_dir, filename), content)
      end)

      # Run migrations via Ecto.Migrator
      Ecto.Migrator.run(Zaq.Repo, tmp_dir, :up, all: true)

      Logger.info("[PostLoader] Migrations completed successfully.")
    rescue
      e ->
        Logger.error("[PostLoader] Migrations failed: #{Exception.message(e)}")
    after
      File.rm_rf!(tmp_dir)
    end
  end
end
