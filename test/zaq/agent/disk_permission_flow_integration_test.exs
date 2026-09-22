defmodule Zaq.Agent.DiskPermissionFlowIntegrationTest do
  @moduledoc """
  A configured agent uses the mock AI provider to list a real Disk folder and
  incrementally update its permissions through the production tool route.

  The test reuses the provisioned Disk data source and owns only a UUID-named
  directory within its configured volume. It is synchronous because the agent
  runtime and its database reads share one SQL Sandbox owner.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Ingestion.Document
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.{EntryCatalog, StorageEntry, VolumeConfig}

  alias Zaq.TestSupport.{
    DiskConfigFixture,
    IntegrationAgent,
    MultiAgentOpenAIStub,
    OpenAIStub
  }

  @tools ~w(list_documents update_document_permissions)

  setup do
    disk_config = DiskConfigFixture.get_or_create!()

    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(disk_config)
    storage_config = Keyword.fetch!(storage_opts, :storage_config)
    volume = Keyword.fetch!(storage_config, :default_volume)
    namespace = "agent-disk-permissions-#{Ecto.UUID.generate()}"
    target_path = "#{namespace}/target"
    child_path = "#{target_path}/child.md"
    sibling_path = "#{namespace}/sibling"
    {:ok, owned_root} = Storage.resolve_path(volume, namespace, storage_opts)

    File.mkdir_p!(Path.join(owned_root, "target"))
    File.mkdir_p!(Path.join(owned_root, "sibling"))
    File.write!(Path.join(owned_root, "target/child.md"), "permission test child")
    File.write!(Path.join(owned_root, "sibling/untouched.md"), "unchanged")
    on_exit(fn -> File.rm_rf!(owned_root) end)

    {:ok, parent} = EntryCatalog.ensure(volume, namespace, "directory")
    {:ok, target} = EntryCatalog.ensure(volume, target_path, "directory")
    {:ok, child} = EntryCatalog.ensure(volume, child_path, "file")
    {:ok, sibling} = EntryCatalog.ensure(volume, sibling_path, "directory")

    {:ok, actor} = People.create_person(%{full_name: "Permission manager #{namespace}"})
    {:ok, reader} = People.create_person(%{full_name: "Permission reader #{namespace}"})
    {:ok, changed_person} = People.create_person(%{full_name: "Changed #{namespace}"})
    {:ok, revoked_person} = People.create_person(%{full_name: "Revoked #{namespace}"})
    {:ok, retained_team} = People.create_team(%{name: "Retained #{namespace}"})
    {:ok, sibling_person} = People.create_person(%{full_name: "Sibling #{namespace}"})

    grant!(parent, %{person_id: actor.id, access_rights: ["read", "manage"]})
    grant!(parent, %{person_id: reader.id, access_rights: ["read"]})
    grant!(target, %{person_id: changed_person.id, access_rights: ["read"]})
    grant!(target, %{person_id: revoked_person.id, access_rights: ["read"]})
    grant!(target, %{team_id: retained_team.id, access_rights: ["read"]})
    grant!(sibling, %{person_id: sibling_person.id, access_rights: ["read"]})

    {:ok, indexed_child} =
      Document.insert_new(%{
        source: "data_source/disk/#{disk_config.id}/#{child.id}",
        content: "indexed permission test child"
      })

    context = %{
      id: namespace,
      path: "#{volume}/#{namespace}",
      disk_config: disk_config,
      actor: actor,
      reader: reader,
      changed_person: changed_person,
      revoked_person: revoked_person,
      retained_team: retained_team,
      sibling_person: sibling_person,
      target: target,
      child: child,
      sibling: sibling,
      indexed_child: indexed_child,
      owned_root: owned_root
    }

    context = Map.put(context, :agent, configured_agent(context, namespace))

    {:ok,
     Map.put(
       context,
       :reader_agent,
       configured_agent(context, "#{namespace}-reader")
     )}
  end

  test "mock AI invokes the permission tool and updates an existing Disk folder", context do
    incoming = %Incoming{
      content: "Update the target folder permissions",
      channel_id: context.id,
      provider: :web,
      person: context.actor
    }

    outgoing =
      Executor.run(incoming, agent_id: to_string(context.agent.id), scope: context.id)

    assert_received {:llm_selected_record, record}
    assert record["id"] == context.target.id
    assert record["kind"] == "folder"
    assert String.starts_with?(record["provenance_ref"], "prov_")

    assert Map.take(record, ~w(id kind parent_id attributes provenance_ref)) == %{
             "id" => context.target.id,
             "kind" => "folder",
             "parent_id" => context.target.parent_id,
             "attributes" => %{"provider_record_id" => context.target.id},
             "provenance_ref" => record["provenance_ref"]
           }

    assert Enum.all?(record["permissions"], fn permission ->
             is_list(permission["attributes"]["access_rights"])
           end)

    assert_received {:llm_permission_result, result}
    assert result["ok"] == true, inspect(result)
    assert result["result"]["status"] == "updated"
    assert result["result"]["file_id"] == context.target.id
    assert context.target.id in result["result"]["affected_file_ids"]
    assert context.child.id in result["result"]["affected_file_ids"]
    assert outgoing.metadata.error == false
    assert outgoing.body == "Folder permissions updated."

    direct = Permissions.list_direct(%StorageEntry{id: context.target.id})

    assert permission_rights(direct, :person_id, context.changed_person.id) == ["read", "write"]
    refute Enum.any?(direct, &(&1.person_id == context.revoked_person.id))
    assert permission_rights(direct, :team_id, context.retained_team.id) == ["read"]

    assert {:ok, %{effective_permissions: child_permissions}} =
             Storage.list_document_grants(context.child.id)

    assert Enum.any?(child_permissions, fn grant ->
             grant.type == "person" and
               grant.target_id == to_string(context.changed_person.id) and
               grant.access_rights == ["read", "write"] and grant.inherited?
           end)

    projected = Permissions.list_direct(context.indexed_child)

    assert permission_rights(projected, :person_id, context.changed_person.id) == [
             "read",
             "write"
           ]

    refute Enum.any?(projected, &(&1.person_id == context.revoked_person.id))
    assert permission_rights(projected, :team_id, context.retained_team.id) == ["read"]

    sibling_direct = Permissions.list_direct(%StorageEntry{id: context.sibling.id})
    assert permission_rights(sibling_direct, :person_id, context.sibling_person.id) == ["read"]
    assert File.read!(Path.join(context.owned_root, "sibling/untouched.md")) == "unchanged"

    refute_received {:llm_stub_error, _}
  end

  test "the agent tool cannot update the folder for a reader-only actor", context do
    incoming = %Incoming{
      content: "Update the target folder permissions",
      channel_id: "#{context.id}-reader",
      provider: :web,
      person: context.reader
    }

    outgoing =
      Executor.run(
        incoming,
        agent_id: to_string(context.reader_agent.id),
        scope: "#{context.id}-reader"
      )

    assert_received {:llm_selected_record, %{"id" => target_id}}
    assert target_id == context.target.id
    assert_received {:llm_permission_result, result}
    assert result["ok"] == false
    assert result["error"]["message"] =~ ":unauthorized"
    assert outgoing.body == "Folder permission update denied."

    direct = Permissions.list_direct(%StorageEntry{id: context.target.id})
    assert permission_rights(direct, :person_id, context.changed_person.id) == ["read"]
    assert permission_rights(direct, :person_id, context.revoked_person.id) == ["read"]
    assert permission_rights(direct, :team_id, context.retained_team.id) == ["read"]

    refute_received {:llm_stub_error, _}
  end

  defp configured_agent(context, scope) do
    test_pid = self()

    handler = fn _conn, body ->
      request = MultiAgentOpenAIStub.decode_request!(body)
      advertised = request["tools"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert advertised == Enum.sort(@tools)

      case MultiAgentOpenAIStub.tool_results(request) do
        [] ->
          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "list_documents",
             %{
               provider: "disk",
               config_id: to_string(context.disk_config.id),
               path: context.path
             },
             model: "gpt-4.1-mini"
           )}

        [listing] ->
          listed_record =
            listing.output
            |> get_in(["result", "records"])
            |> Enum.find(&(&1["id"] == context.target.id))

          record =
            listed_record
            |> Map.take(~w(id kind parent_id permissions attributes provenance_ref))
            |> update_in(["attributes"], &Map.take(&1, ["provider_record_id"]))

          send(test_pid, {:llm_selected_record, record})

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "update_document_permissions",
             %{
               record: record,
               grants: [
                 %{
                   type: "person",
                   target_id: to_string(context.changed_person.id),
                   access_rights: ["read", "write"]
                 }
               ],
               revocations: [
                 %{type: "person", target_id: to_string(context.revoked_person.id)}
               ]
             },
             model: "gpt-4.1-mini"
           )}

        [listing, update] ->
          assert listing.output["ok"] == true
          send(test_pid, {:llm_permission_result, update.output})

          {200, MultiAgentOpenAIStub.text_sse(permission_answer(update.output), "gpt-4.1-mini")}
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child)

    IntegrationAgent.create!(
      endpoint,
      scope,
      "Use the enabled Disk tools to update the requested folder permissions.",
      Enum.map(@tools, &("data_source." <> &1))
    )
  end

  defp grant!(entry, attrs) do
    assert {:ok, _permission} = Permissions.grant(%StorageEntry{id: entry.id}, attrs)
  end

  defp permission_answer(%{"ok" => true}), do: "Folder permissions updated."
  defp permission_answer(_result), do: "Folder permission update denied."

  defp permission_rights(permissions, field, id) do
    permissions
    |> Enum.find(&(Map.fetch!(&1, field) == id))
    |> then(&(&1 && Enum.sort(&1.access_rights)))
  end
end
