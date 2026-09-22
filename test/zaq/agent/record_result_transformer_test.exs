defmodule Zaq.Agent.RecordResultTransformerTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.RecordResultTransformer
  alias Zaq.Contracts.Record

  test "projects signed records and permissions to the advertised minimum" do
    permission = %Record{
      id: "permission-1",
      kind: :permission,
      name: "Reader",
      attributes: %{"type" => "person", "target_id" => "7", "access_rights" => ["read"]}
    }

    record = %Record{
      id: "folder-1",
      kind: :folder,
      name: "Folder",
      parent_id: "parent-1",
      path: "parent-1/folder-1",
      permissions: [permission],
      attributes: %{"provider_record_id" => "provider-folder-1", "private" => "omitted"},
      provenance_ref: "prov_alias"
    }

    assert {:ok, {:ok, %{record: projected}, []}} =
             RecordResultTransformer.project_tool_result(
               %{},
               {:ok, %{record: record}, []},
               %{}
             )

    assert projected == %{
             "id" => "folder-1",
             "kind" => "folder",
             "name" => "Folder",
             "content" => nil,
             "parent_id" => "parent-1",
             "path" => "parent-1/folder-1",
             "mime_type" => nil,
             "size" => nil,
             "materialization_handle" => nil,
             "permissions" => [
               %{
                 "id" => "permission-1",
                 "kind" => "permission",
                 "name" => "Reader",
                 "attributes" => %{
                   "type" => "person",
                   "target_id" => "7",
                   "access_rights" => ["read"]
                 }
               }
             ],
             "attributes" => %{"provider_record_id" => "provider-folder-1"},
             "provenance_ref" => "prov_alias"
           }
  end

  test "leaves unsigned materialized records intact" do
    record = %Record{id: "file-1", kind: :file, content: "body"}

    assert {:ok, {:ok, %{record: ^record}, []}} =
             RecordResultTransformer.project_tool_result(
               %{},
               {:ok, %{record: record}, []},
               %{}
             )
  end
end
