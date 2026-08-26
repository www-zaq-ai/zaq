Code.require_file(
  "priv/repo/migrations/20260825000000_migrate_disk_volumes_to_channel_config.exs"
)

defmodule Zaq.Repo.Migrations.MigrateDiskVolumesToChannelConfigTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.Repo.Migrations.MigrateDiskVolumesToChannelConfig, as: Migration

  setup do
    original_import = Application.get_env(:zaq, :storage_volume_import)
    original_storage = Application.get_env(:zaq, Zaq.Storage)
    original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)

    on_exit(fn ->
      restore_env(:storage_volume_import, original_import)
      restore_env(Zaq.Storage, original_storage)
      restore_env(Zaq.Ingestion, original_ingestion)
    end)
  end

  test "configured_volumes stores paths relative to the Storage base" do
    root = Path.join(System.tmp_dir!(), "zaq_volume_migration_test")

    Application.put_env(:zaq, Zaq.Storage, base_path: root)

    Application.put_env(:zaq, :storage_volume_import,
      volumes: %{
        "documents" => Path.join(root, "documents"),
        "archives" => "archives"
      }
    )

    assert Migration.configured_volumes() == [
             %{"name" => "archives", "path" => "archives"},
             %{"name" => "documents", "path" => "documents"}
           ]
  end

  test "rename_legacy_disk_config preserves the existing zaq_local config id" do
    Repo.delete_all(ChannelConfig)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [%{id: legacy_id}]} =
      Repo.insert_all(
        ChannelConfig,
        [
          %{
            name: "Legacy local",
            provider: "zaq_local",
            kind: "data_source",
            enabled: true,
            url: "",
            token: "",
            settings: %{"volumes" => [%{"name" => "documents", "path" => "documents"}]},
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    Migration.rename_legacy_disk_config(Repo, now)

    assert %{id: id, provider: "disk", name: "Disk"} = Repo.get!(ChannelConfig, legacy_id)
    assert id == legacy_id
  end

  test "rename_legacy_disk_config leaves zaq_local unchanged when disk already exists" do
    Repo.delete_all(ChannelConfig)

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Disk",
      provider: "disk",
      kind: "data_source",
      enabled: true,
      settings: %{"volumes" => [%{"name" => "documents", "path" => "documents"}]}
    })
    |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(ChannelConfig, [
      %{
        name: "Legacy local",
        provider: "zaq_local",
        kind: "data_source",
        enabled: true,
        url: "",
        token: "",
        settings: %{"volumes" => [%{"name" => "legacy", "path" => "legacy"}]},
        inserted_at: now,
        updated_at: now
      }
    ])

    Migration.rename_legacy_disk_config(Repo, now)

    assert Repo.get_by!(ChannelConfig, provider: "zaq_local").name == "Legacy local"
    assert Repo.get_by!(ChannelConfig, provider: "disk").name == "Disk"
  end

  defp restore_env(key, nil), do: Application.delete_env(:zaq, key)
  defp restore_env(key, value), do: Application.put_env(:zaq, key, value)
end
