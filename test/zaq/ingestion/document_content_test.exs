defmodule Zaq.Ingestion.DocumentContentTest do
  use Zaq.DataCase, async: false
  import Mox
  alias Zaq.Accounts.People
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Ingestion.{Document, DocumentContent}
  alias Zaq.Permissions
  setup :verify_on_exit!

  setup do
    {:ok, person} = People.create_person(%{full_name: "Source reader"})
    %{person: person}
  end

  test "missing identity, missing documents and private sources fail closed", %{person: person} do
    {:ok, document} = Document.create(%{source: "private-source.txt"})

    for id <- [nil, 0, -1, "1"],
        do: assert(DocumentContent.authorize(document.source, id) == {:error, :not_found})

    assert DocumentContent.read("missing.txt", person.id) == {:error, :not_found}
    assert DocumentContent.read(document.source, person.id) == {:error, :not_found}
    grant(document, person)
    assert DocumentContent.read(document.source, person.id) == {:error, :not_found}
  end

  test "source ACL is checked before returning an opaque reference without dispatch",
       %{person: person} do
    {:ok, handle} = DataSourceDocument.issue("drive", "source", %{"config_id" => "config"})

    {:ok, document} =
      Document.create(%{
        source: "data_source/drive/config/source",
        metadata: %{"materialization_handle" => handle}
      })

    assert DocumentContent.read(document.source, person.id, node_router: Zaq.NodeRouterMock) ==
             {:error, :not_found}

    grant(document, person)

    assert DocumentContent.read(document.source, person.id, node_router: Zaq.NodeRouterMock) ==
             {:ok,
              %{
                materialization_handle: handle,
                name: document.title,
                mime_type: "application/octet-stream"
              }}
  end

  test "external resources without names retain a usable source filename", %{person: person} do
    {:ok, handle} = DataSourceDocument.issue("drive", "unnamed", %{"config_id" => "config"})

    {:ok, document} =
      Document.create(%{
        source: "data_source/drive/config/unnamed",
        metadata: %{"materialization_handle" => handle}
      })

    Repo.update!(Ecto.Changeset.change(document, title: nil))
    grant(document, person)

    assert {:ok,
            %{
              materialization_handle: ^handle,
              name: "unnamed",
              mime_type: "application/octet-stream"
            }} =
             DocumentContent.read(document.source, person.id, node_router: Zaq.NodeRouterMock)
  end

  test "authorized local originals are read within storage roots", %{person: person} do
    root = Path.join(System.tmp_dir!(), "people-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: root, volumes: %{})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:zaq, Zaq.Storage, previous),
        else: Application.delete_env(:zaq, Zaq.Storage)

      File.rm_rf!(root)
    end)

    File.write!(Path.join(root, "local.txt"), "Original bytes")
    {:ok, document} = Document.create(%{source: "local.txt", content: "Converted text"})
    grant(document, person)

    assert {:ok, %{content: "Original bytes", name: "local.txt", mime_type: "text/plain"}} =
             DocumentContent.read(document.source, person.id)
  end

  defp grant(document, person),
    do:
      Permissions.grant({"document", to_string(document.id)}, %{
        person_id: person.id,
        access_rights: ["read"]
      })
end
