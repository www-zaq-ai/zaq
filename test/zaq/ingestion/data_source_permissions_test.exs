defmodule Zaq.Ingestion.DataSourcePermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.ExternalPermissions
  alias Zaq.Permissions

  defmodule StubNodeRouter do
    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:dispatch, opts[:action], event.request, event.actor, opts})

      response =
        case opts[:action] do
          :data_source_list_permissions ->
            fallback =
              Process.get(
                :permission_response,
                {:ok,
                 %{
                   records: [
                     %Record{
                       id: "public",
                       kind: :permission,
                       attributes: %{"type" => "public", "access_rights" => ["read"]}
                     }
                   ]
                 }}
              )

            Map.get(
              Process.get(:permission_responses_by_file, %{}),
              event.request.params["file_id"],
              fallback
            )
        end

      %{event | response: response}
    end
  end

  test "confirmed mutation failures invalidate only failed source projections and process later documents" do
    references = ["mutation-first", "mutation-second", "mutation-third"]
    everyone = Permissions.everyone_team_id()

    documents =
      Enum.map(references, fn id ->
        {:ok, document} = Document.insert_new(%{source: "data_source/disk/12/#{id}"})

        {:ok, _} =
          Permissions.grant(document, %{
            team_id: everyone,
            source_key: "source:#{document.source}",
            access_rights: ["read"]
          })

        {:ok, manual} = Permissions.grant(document, %{team_id: everyone, access_rights: ["read"]})

        {:ok, other} =
          Permissions.grant(document, %{
            team_id: everyone,
            source_key: "unrelated-source",
            access_rights: ["read"]
          })

        {document, Enum.sort([manual.id, other.id])}
      end)

    Process.put(:permission_responses_by_file, %{
      "mutation-first" => {:error, :provider_timeout},
      "mutation-second" => {:ok, %{records: []}},
      "mutation-third" => {:error, :unauthorized}
    })

    assert {:error, {:document_sync_failed, "mutation-first", :provider_timeout}} =
             Ingestion.sync_data_source_permission_projection("disk", 12, references, %{
               node_router: StubNodeRouter,
               actor: %{person_id: 7},
               source_acl_mutation_committed: true
             })

    for {document, preserved_ids} <- documents do
      assert Enum.sort(Enum.map(Permissions.list_direct(document), & &1.id)) == preserved_ids
    end

    for id <- references do
      assert_received {:dispatch, :data_source_list_permissions, %{params: %{"file_id" => ^id}},
                       _, _}
    end
  end

  test "a denied standalone refresh cannot invalidate a source projection" do
    {:ok, document} = Document.insert_new(%{source: "data_source/disk/12/standalone-denied"})

    {:ok, grant} =
      Permissions.grant(document, %{
        team_id: Permissions.everyone_team_id(),
        source_key: "source:#{document.source}",
        access_rights: ["read"]
      })

    Process.put(:permission_response, {:error, :unauthorized})

    assert {:error, {:document_sync_failed, "standalone-denied", :unauthorized}} =
             Ingestion.sync_data_source_permission_projection(
               "disk",
               12,
               ["standalone-denied"],
               %{node_router: StubNodeRouter, actor: %{person_id: 7}}
             )

    assert [%{id: id}] = Permissions.list_direct(document)
    assert id == grant.id
  end

  test "source permission changes revoke the same ownership key introduced before ingestion" do
    {:ok, document} = Document.insert_new(%{source: "data_source/disk/12/refresh-file"})
    everyone = Permissions.everyone_team_id()
    {:ok, manual} = Permissions.grant(document, %{team_id: everyone, access_rights: ["read"]})

    {:ok, other} =
      Permissions.grant(document, %{
        team_id: everyone,
        source_key: "other-source",
        access_rights: ["read"]
      })

    record = %Record{
      id: "refresh-file",
      kind: :file,
      permissions: [
        %Record{
          id: "public",
          kind: :permission,
          attributes: %{"type" => "public", "access_rights" => ["read"]}
        }
      ]
    }

    {:ok, record} = Provenance.seal(record, %{"provider" => "disk", "config_id" => 12})
    assert :ok = ExternalPermissions.apply(record, [document])

    assert Enum.any?(
             Permissions.list_direct(document),
             &(&1.source_key == "source:#{document.source}")
           )

    Process.put(:permission_response, {:ok, %{records: []}})

    assert :ok =
             Ingestion.sync_data_source_permission_projection("disk", 12, ["refresh-file"], %{
               node_router: StubNodeRouter,
               actor: %{person_id: 7},
               skip_permissions: true
             })

    assert Enum.sort(Enum.map(Permissions.list_direct(document), & &1.id)) ==
             Enum.sort([manual.id, other.id])

    assert_received {:dispatch, :data_source_list_permissions, _, _, opts}
    assert opts[:confidential] == true
  end

  test "incomplete provider permission pages leave existing ownership unchanged" do
    {:ok, document} = Document.insert_new(%{source: "data_source/disk/12/incomplete-file"})

    {:ok, grant} =
      Permissions.grant(document, %{
        team_id: Permissions.everyone_team_id(),
        source_key: "source:#{document.source}",
        access_rights: ["read"]
      })

    Process.put(:permission_response, {:ok, %{records: [], pagination: %{has_more?: true}}})

    assert {:error, {:document_sync_failed, "incomplete-file", :incomplete_permissions}} =
             Ingestion.sync_data_source_permission_projection("disk", 12, ["incomplete-file"], %{
               node_router: StubNodeRouter,
               actor: %{person_id: 7}
             })

    assert [%{id: id}] = Permissions.list_direct(document)
    assert id == grant.id
  end

  test "incremental source changes reuse indexed-document permission synchronization" do
    {:ok, document} =
      Document.insert_new(%{
        source: "data_source/disk/12/file-1",
        content: "indexed"
      })

    actor = %{person_id: 7}
    context = %{node_router: StubNodeRouter, actor: actor, skip_permissions: true}

    assert :ok =
             Ingestion.sync_data_source_permission_projection(
               "disk",
               "12",
               ["folder-1", "file-1"],
               context
             )

    assert_received {:dispatch, :data_source_list_permissions,
                     %{provider: "disk", params: %{"config_id" => "12", "file_id" => "file-1"}},
                     ^actor, list_opts}

    assert list_opts[:skip_permissions] == true

    assert [permission] = Permissions.list_direct(document)
    assert permission.team_id == Permissions.everyone_team_id()
    assert permission.access_rights == ["read"]
  end

  test "reports the affected file when indexed-document synchronization fails" do
    {:ok, _document} =
      Document.insert_new(%{source: "data_source/disk/12/file-1", content: "indexed"})

    Process.put(:permission_response, {:error, :provider_timeout})

    assert {:error, {:document_sync_failed, "file-1", :provider_timeout}} =
             Ingestion.sync_data_source_permission_projection(
               "disk",
               "12",
               ["folder-1", "file-1"],
               %{node_router: StubNodeRouter, skip_permissions: true}
             )
  end
end
