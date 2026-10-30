defmodule Zaq.Agent.Tools.DataSource.AttachDocumentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Agent.{Factory, OpaqueAliases, RequestEffects}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

  test "validated commands preserve native scope, expose Records and never deliver files" do
    record = record("a")

    for operation <- ["add", "remove", "replace"] do
      assert {:ok, %{records: [^record]}, [effect]} =
               Jido.Exec.run(
                 AttachDocuments,
                 %{operation: operation, records: [record]},
                 context()
               )

      assert effect.path == [:request_effect]
      assert effect.value.payload.operation == operation
      assert effect.value.request_id == "request"
      assert effect.value.incarnation == self()
    end

    assert {:ok, %{records: []}, [_]} =
             Jido.Exec.run(AttachDocuments, %{operation: "replace", records: []}, context())

    assert {:ok, [AttachDocuments]} = Registry.resolve_modules(["data_source.attach_document"])
    assert {:ok, []} = Registry.resolve_modules([])

    assert {:ok, _, [effect]} =
             Jido.Exec.run(
               AttachDocuments,
               %{operation: "replace", records: [], request_id: "forged"},
               context()
             )

    assert effect.value.request_id == "request"
  end

  test "requires trusted request context and identity even for clearing an empty selection" do
    for ctx <- [%{}, Map.delete(context(), :request_id), Map.put(context(), :actor, nil)],
        records <- [[], [record("a")]] do
      assert {:error, _} =
               Jido.Exec.run(AttachDocuments, %{operation: "replace", records: records}, ctx)
    end

    denied = %{context() | actor: %Person{id: 2, email: "other@example.test", channels: []}}
    params = %{operation: "add", records: [record("a")]}
    assert {:error, _} = Jido.Exec.run(AttachDocuments, params, denied)

    assert {:ok, _, [_]} =
             Jido.Exec.run(AttachDocuments, params, Map.put(denied, :skip_permissions, true))
  end

  property "one malformed or forged Record rejects the whole batch without effects" do
    check all(ids <- list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 8)) do
      records = Enum.map(ids, &record/1)
      forged = %{record("forged") | id: "changed"}

      for bad <- [forged, %{record("denied") | permissions: nil}, %{"id" => "unsigned"}, nil] do
        assert {:error, _} =
                 Jido.Exec.run(
                   AttachDocuments,
                   %{operation: "add", records: records ++ [bad]},
                   context()
                 )
      end
    end
  end

  test "rejects unsupported operations, folders and oversized batches" do
    record = record("a")
    {:ok, folder} = Provenance.seal(%{record | kind: :folder})

    for params <- [
          %{operation: "delete", records: [record]},
          %{operation: "add", records: "a"},
          %{operation: "add", records: List.duplicate(record, 101)},
          %{operation: "add", records: [folder]}
        ] do
      assert {:error, _} = Jido.Exec.run(AttachDocuments, params, context())
    end
  end

  test "a signed source without a config cannot select an unavailable provider's record" do
    {:ok, source} =
      Provenance.seal(record("source-file"), %{"provider" => "attachment-test-unknown-provider"})

    assert {:ok, claims} = Provenance.verify(source)
    refute Map.has_key?(claims, "config_id")

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: %{reason: :unauthorized}}} =
             Jido.Exec.run(
               AttachDocuments,
               %{operation: "add", records: [record("allowed"), source]},
               context()
             )
  end

  test "the run callback rejects a forged record even without framework validation" do
    forged = %{record("signed") | id: "substituted"}

    assert {:error, :invalid_record} =
             AttachDocuments.run(
               %{operation: "replace", records: [record("allowed"), forged]},
               context()
             )
  end

  test "Factory expands schema-declared aliases before validated Action execution" do
    ctx = Map.put(context(), :opaque_alias_scope, make_ref())
    on_exit(fn -> OpaqueAliases.clear_scope(ctx.opaque_alias_scope) end)
    call = %{action_module: AttachDocuments, arguments: %{}, id: "call", name: "attach_documents"}

    assert {:ok, {:ok, output, []}} =
             Factory.after_tool_call(
               call,
               {:ok, %{records: [record("alias")]}, []},
               ctx
             )

    assert [%{"provenance_ref" => "prov_" <> _}] = output.records

    assert {:ok, expanded} =
             Factory.before_tool_call(
               %{call | arguments: %{operation: "add", records: output.records}},
               ctx
             )

    assert {:ok, _, [_]} = Jido.Exec.run(AttachDocuments, expanded.arguments, ctx)
    OpaqueAliases.clear_scope(ctx.opaque_alias_scope)
  end

  defp context do
    %{
      request_id: "request",
      actor: %Person{id: 1, email: "reader@example.test", channels: []},
      state: %{
        request_effects: RequestEffects.new("request", self(), [AttachDocuments])
      }
    }
  end

  defp record(id) do
    permission = %Record{
      id: "read",
      kind: :permission,
      attributes: %{
        "principal" => %{"channel" => "email", "identifier" => "reader@example.test"},
        "access_rights" => ["read"]
      }
    }

    {:ok, record} =
      Provenance.seal(%Record{id: id, kind: :file, name: id, permissions: [permission]})

    record
  end
end
