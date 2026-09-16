defmodule Zaq.TestSupport.PeopleSourceFixture do
  @moduledoc "Sandboxed, unindexed disk source shared by People resource and browser tests."
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.Storage
  alias Zaq.Storage.EntryCatalog

  def create(person, content, name \\ "source.md") do
    namespace = "people-source-#{Ecto.UUID.generate()}"
    {:ok, root} = Storage.resolve_path("default", namespace)
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, name), content)

    config = ChannelConfig.get_by_provider("disk") || create_config(namespace)

    {:ok, entry} = EntryCatalog.ensure("default", "#{namespace}/#{name}", "file")

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
      settings: %{"volumes" => [%{"name" => "default", "path" => "."}]}
    })
    |> Repo.insert!()
  end
end
