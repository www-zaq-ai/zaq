defmodule Zaq.TestSupport.PeopleSourceFixture do
  @moduledoc "Sandboxed, unindexed disk source shared by People resource and browser tests."
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.Storage
  alias Zaq.Storage.{EntryCatalog, VolumeConfig}

  def create(person, content, name \\ "source.md") do
    namespace = "people-source-#{Ecto.UUID.generate()}"
    config = create_config(namespace)
    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(config)
    {:ok, root} = Storage.resolve_path(namespace, ".", storage_opts)
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, name), content)

    {:ok, entry} = EntryCatalog.ensure(namespace, name, "file")

    {:ok, grant} =
      Storage.grant_document_access(entry.id, %{person_id: person.id, access_rights: ["read"]})

    %{
      source: "data_source/disk/#{config.id}/#{entry.id}",
      entry: entry,
      grant: grant,
      config: config
    }
  end

  defp create_config(namespace) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: namespace,
      provider: "disk",
      kind: "data_source",
      enabled: true,
      settings: %{"volumes" => [%{"name" => namespace, "path" => namespace}]}
    })
    |> Repo.insert!()
  end
end
