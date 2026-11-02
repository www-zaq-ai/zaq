defmodule Zaq.Agent.Tools.DataSource.AttachDocumentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Agent.{Factory, OpaqueAliases}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

  test "validated commands preserve native scope, expose Records and never deliver files" do
    record = record("a")

    for operation <- ["add", "remove", "replace"] do
      assert {:ok, %{operation: ^operation, records: [^record]}} =
               Jido.Exec.run(
                 AttachDocuments,
                 %{operation: operation, records: [record]},
                 context()
               )
    end

    assert {:ok, %{operation: "replace", records: []}} =
             Jido.Exec.run(AttachDocuments, %{operation: "replace", records: []}, context())

    assert {:ok, [AttachDocuments]} = Registry.resolve_modules(["data_source.attach_document"])
    assert {:ok, []} = Registry.resolve_modules([])

    assert {:ok, %{operation: "replace", records: []}} =
             Jido.Exec.run(
               AttachDocuments,
               %{operation: "replace", records: [], request_id: "forged"},
               context()
             )
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

    assert {:ok, _} =
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

    assert {:ok, _} = Jido.Exec.run(AttachDocuments, expanded.arguments, ctx)
    OpaqueAliases.clear_scope(ctx.opaque_alias_scope)
  end

  test "selection output aliases resolve only within the owning live scope" do
    scope = make_ref()
    ctx = %{opaque_alias_scope: scope}
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
    record = record("output")
    output = %{operation: "add", records: [record]}

    assert {:ok, {:ok, aliased, []}} =
             Factory.after_tool_call(%{action_module: AttachDocuments}, {:ok, output, []}, ctx)

    assert {:ok, %{operation: "add", records: [expanded_record]}} =
             OpaqueAliases.expand_tool_output(AttachDocuments, aliased, ctx)
             |> then(fn {:ok, expanded} -> AttachDocuments.validate_output(expanded) end)

    assert expanded_record.id == record.id
    assert expanded_record.provenance_ref == record.provenance_ref
    assert {:ok, _} = Provenance.verify(expanded_record)

    assert {:error, _} = OpaqueAliases.expand_tool_output(AttachDocuments, aliased, %{})

    assert {:error, _} =
             OpaqueAliases.expand_tool_output(AttachDocuments, aliased, %{
               opaque_alias_scope: make_ref()
             })

    OpaqueAliases.clear_scope(scope)
    assert {:error, _} = OpaqueAliases.expand_tool_output(AttachDocuments, aliased, ctx)
  end

  test "native request state must match and remain pending" do
    for state <- [
          %{},
          %{requests: nil},
          %{requests: %{"other" => %{status: :pending}}},
          %{requests: %{"request" => %{status: :completed}}}
        ] do
      assert {:error, _} =
               Jido.Exec.run(AttachDocuments, %{operation: "replace", records: []}, %{
                 context()
                 | state: state
               })
    end
  end

  defp context do
    %{
      request_id: "request",
      actor: %Person{id: 1, email: "reader@example.test", channels: []},
      state: %{
        requests: %{"request" => %{status: :pending}}
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
