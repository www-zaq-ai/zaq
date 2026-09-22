defmodule Zaq.Ingestion.DataSourcePermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions

  defmodule StubNodeRouter do
    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:dispatch, opts[:action], event.request, event.actor, opts})

      response =
        case opts[:action] do
          :data_source_list_permissions ->
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
        end

      %{event | response: response}
    end
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
