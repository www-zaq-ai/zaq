defmodule Zaq.Repo.Migrations.MigrateDiskVolumesToChannelConfig do
  use Ecto.Migration
  import Ecto.Query

  @disable_ddl_transaction true

  def up do
    execute(fn ->
      repo = repo()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      rename_legacy_disk_config(repo, now)

      volumes = configured_volumes()

      if volumes != [] do
        settings = %{"volumes" => volumes}

        case repo.query!("SELECT id, settings FROM channel_configs WHERE provider = $1 LIMIT 1", [
               "disk"
             ]).rows do
          [] ->
            repo.insert_all("channel_configs", [
              %{
                name: "Disk",
                provider: "disk",
                kind: "data_source",
                url: "",
                token: "",
                enabled: base_path_present?(),
                settings: settings,
                inserted_at: now,
                updated_at: now
              }
            ])

          [[id, existing_settings]] ->
            existing_settings = existing_settings || %{}

            if Map.get(existing_settings, "volumes", []) == [] do
              repo.update_all(
                from(c in "channel_configs", where: c.id == ^id),
                set: [settings: Map.put(existing_settings, "volumes", volumes), updated_at: now]
              )
            end
        end
      end
    end)
  end

  def down, do: :ok

  def rename_legacy_disk_config(repo, now) do
    disk_exists? =
      repo.query!("SELECT 1 FROM channel_configs WHERE provider = $1 LIMIT 1", ["disk"]).rows !=
        []

    unless disk_exists? do
      repo.update_all(
        from(c in "channel_configs", where: c.provider == "zaq_local"),
        set: [provider: "disk", name: "Disk", updated_at: now]
      )
    end
  end

  def configured_volumes do
    import_config = Application.get_env(:zaq, :storage_volume_import, [])
    storage = Application.get_env(:zaq, Zaq.Storage, [])
    ingestion = Application.get_env(:zaq, Zaq.Ingestion, [])

    volumes =
      Keyword.get(import_config, :volumes) || Keyword.get(storage, :volumes) ||
        Keyword.get(ingestion, :volumes) || env_volumes() || %{}

    base_path = Keyword.get(storage, :base_path)

    volumes
    |> Enum.map(fn {name, path} ->
      %{"name" => to_string(name), "path" => normalize_volume_path(path, base_path)}
    end)
    |> Enum.reject(fn %{"name" => name, "path" => path} -> name == "" or path == "" end)
  end

  defp base_path_present? do
    storage = Application.get_env(:zaq, Zaq.Storage, [])

    case Keyword.get(storage, :base_path) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp normalize_volume_path(path, base_path) do
    path = path |> to_string() |> String.trim()

    cond do
      path == "" ->
        ""

      Path.type(path) != :absolute ->
        path

      is_binary(base_path) and String.trim(base_path) != "" ->
        path
        |> Path.expand()
        |> Path.relative_to(Path.expand(base_path))

      true ->
        path
    end
  end

  defp env_volumes do
    volumes_env = System.get_env("STORAGE_VOLUMES") || System.get_env("INGESTION_VOLUMES")

    case volumes_env do
      value when is_binary(value) and value not in ["", "/"] ->
        value
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Map.new(fn name -> {name, name} end)

      _ ->
        nil
    end
  end
end
