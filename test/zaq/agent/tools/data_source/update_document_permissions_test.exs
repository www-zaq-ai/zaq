defmodule Zaq.Agent.Tools.DataSource.UpdateDocumentPermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.UpdateDocumentPermissions
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{record: %Record{} = record, changes: changes}} = event) do
      send(self(), {
        :dispatch,
        event.next_hop.destination,
        event.opts[:action],
        record,
        changes,
        event.actor,
        event.opts
      })

      %{
        Event.new(%{}, :channels)
        | response:
            {:ok,
             %{
               status: "updated",
               file_id: record.id,
               affected_file_ids: [record.id]
             }}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :unsupported}}
  end

  defp record do
    %Record{
      id: "f1",
      kind: :folder,
      attributes: %{"provider" => "disk", "config_id" => "12"}
    }
  end

  defp signed_record do
    {:ok, sealed} = Provenance.seal(record(), %{"provider" => "disk", "config_id" => "12"})
    sealed
  end

  test "dispatches incremental grants and revocations through Channels" do
    grants = [%{type: "person", target_id: "7", access_rights: ["read", "write"]}]
    revocations = [%{type: "team", target_id: "9"}]
    actor = %{provider: "bo", person_id: 3}

    assert {:ok, %{status: "updated", affected_file_ids: ["f1"]}} =
             UpdateDocumentPermissions.run(
               %{record: record(), grants: grants, revocations: revocations},
               %{node_router: StubNodeRouter, actor: actor, skip_permissions: true}
             )

    assert_received {:dispatch, :channels, :data_source_update_permissions, %Record{id: "f1"},
                     %{"grants" => ^grants, "revocations" => ^revocations}, ^actor, opts}

    assert opts[:skip_permissions] == true
  end

  test "allows grant-only and revoke-only changes" do
    assert {:ok, _} =
             UpdateDocumentPermissions.run(
               %{record: record(), grants: [%{type: "public", access_rights: ["read"]}]},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :channels, :data_source_update_permissions, _,
                     %{"grants" => [_], "revocations" => []}, _, _}

    assert {:ok, _} =
             UpdateDocumentPermissions.run(
               %{record: record(), revocations: [%{type: "public"}]},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :channels, :data_source_update_permissions, _,
                     %{"grants" => [], "revocations" => [_]}, _, _}
  end

  test "rejects empty changes and conflicting principals" do
    assert {:error, _} =
             Jido.Exec.run(UpdateDocumentPermissions, %{record: record()}, %{})

    params = %{
      record: record(),
      grants: [%{type: "person", target_id: "7", access_rights: ["read"]}],
      revocations: [%{type: "person", target_id: "7"}]
    }

    assert {:error, _} = Jido.Exec.run(UpdateDocumentPermissions, params, %{})

    assert {:error, _} =
             Jido.Exec.run(
               UpdateDocumentPermissions,
               %{
                 record: signed_record(),
                 grants: [
                   %{type: "person", target_id: "not-an-id", access_rights: ["read"]}
                 ]
               },
               %{}
             )

    assert {:error, _} =
             Jido.Exec.run(
               UpdateDocumentPermissions,
               %{
                 record: signed_record(),
                 grants: [%{type: "public", access_rights: ["write"]}]
               },
               %{}
             )
  end

  test "converts JSON-shaped parameters through the Action schema" do
    params = %{
      "record" => signed_record(),
      "grants" => [
        %{"type" => "person", "target_id" => "7", "access_rights" => ["read"]}
      ]
    }

    assert {:ok, converted} = UpdateDocumentPermissions.on_before_validate_params(params)
    assert converted.record == signed_record()
    assert converted.grants == [%{type: "person", target_id: "7", access_rights: ["read"]}]
    assert {:ok, _validated} = UpdateDocumentPermissions.validate_params(converted)
  end

  test "formats unsupported provider failures" do
    assert {:error, "Data source permission update failed: :unsupported"} =
             UpdateDocumentPermissions.run(
               %{record: record(), revocations: [%{type: "public"}]},
               %{node_router: ErrorNodeRouter}
             )
  end
end
