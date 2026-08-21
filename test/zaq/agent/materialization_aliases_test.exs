defmodule Zaq.Agent.MaterializationAliasesTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Agent.{Factory, MaterializationAliases}
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Materialization.Handle

  defmodule DirectHandleAction do
    def schema do
      Zoi.object(%{
        materialization_handle: Handle.zoi_type() |> Zoi.optional(),
        note: Zoi.string() |> Zoi.optional()
      })
    end

    def output_schema do
      Zoi.object(%{
        record: Record.zoi_type() |> Zoi.optional(),
        raw: Zoi.any() |> Zoi.optional()
      })
    end
  end

  defmodule RecordListAction do
    def schema, do: []

    def output_schema do
      Zoi.object(%{
        records: Zoi.list(Record.zoi_type()) |> Zoi.optional()
      })
    end
  end

  defmodule NoHandleAction do
    def schema, do: Zoi.object(%{query: Zoi.string()})
    def output_schema, do: Zoi.object(%{answer: Zoi.string()})
  end

  defmodule RecordStructAction do
    def schema, do: Zoi.object(%{record: Zoi.struct(Record)})
  end

  defmodule RecordPageAction do
    def output_schema, do: Zoi.object(%{page: Zoi.struct(RecordPage)})
  end

  defmodule RecordPageFieldsAction do
    def output_schema do
      Zoi.object(%{
        page: Zoi.struct(RecordPage, %{records: Zoi.list(Zoi.struct(Record))})
      })
    end
  end

  defmodule TestWrapper do
    defstruct [:handle]
  end

  defmodule GenericStructAction do
    def schema do
      Zoi.object(%{wrapper: Zoi.struct(TestWrapper, %{handle: Handle.zoi_type()})})
    end
  end

  defmodule DefaultUnionAction do
    def schema do
      Zoi.object(%{
        default_handle: Zoi.default(Handle.zoi_type(), nil),
        union_handle: Zoi.union([Handle.zoi_type(), Zoi.integer()])
      })
    end
  end

  defmodule LegacyNimbleAction do
    def schema do
      [
        record: [type: {:struct, Record}],
        page: [type: {:struct, RecordPage}],
        records: [type: {:list, {:struct, Record}}],
        ignored: [type: :string],
        other: :ignored
      ]
    end
  end

  defmodule NonStringKeyAction do
    def schema, do: [{123, [type: {:struct, Record}]}]
  end

  defmodule BinaryKeyAction do
    def schema do
      Zoi.object(%{
        "materialization_handle" => Handle.zoi_type(),
        "zaq_uncreated_materialization_alias_key" => Handle.zoi_type()
      })
    end
  end

  setup do
    scope = "test-scope-#{System.unique_integer([:positive])}"
    MaterializationAliases.clear_scope(scope)
    on_exit(fn -> MaterializationAliases.clear_scope(scope) end)
    {:ok, scope: scope}
  end

  test "aliases output handles and expands aliases back for declared handle input", %{
    scope: scope
  } do
    handle = handle!("file-1")
    effects = [%{event: :kept}]

    result = {:ok, %{record: record("file-1", handle), raw: handle}, effects}
    tool_call = %{id: "call-1", name: "direct", arguments: %{}, action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}, raw: ^handle}, ^effects}} =
             MaterializationAliases.alias_tool_result(tool_call, result, %{
               materialization_alias_scope: scope
             })

    assert String.starts_with?(alias, "mat_")

    aliased_call = %{tool_call | arguments: %{"materialization_handle" => alias, "note" => alias}}

    assert {:ok, expanded} =
             MaterializationAliases.expand_tool_call(aliased_call, %{
               materialization_alias_scope: scope
             })

    assert expanded.action_module == DirectHandleAction
    assert expanded.arguments["materialization_handle"] == handle
    assert expanded.arguments["note"] == alias
  end

  test "aliases lists of records through the Factory interceptor callback", %{scope: scope} do
    first = handle!("file-1")
    second = handle!("file-2")

    tool_call = %{id: "call-1", name: "records", arguments: %{}, action_module: RecordListAction}
    result = {:ok, %{records: [record("file-1", first), record("file-2", second)]}, []}

    assert {:ok, {:ok, %{records: records}, []}} =
             Factory.after_tool_call(tool_call, result, %{materialization_alias_scope: scope})

    assert [
             %Record{materialization_handle: first_alias},
             %Record{materialization_handle: second_alias}
           ] =
             records

    assert String.starts_with?(first_alias, "mat_")
    assert String.starts_with?(second_alias, "mat_")
    refute first_alias == second_alias
  end

  test "propagates missing alias scope errors through the Factory interceptor" do
    tool_call = %{id: "call-1", name: "direct", arguments: %{}, action_module: DirectHandleAction}
    result = {:ok, %{record: record("file-1", handle!("file-1"))}, []}

    assert {:error, :missing_materialization_alias_scope} =
             Factory.after_tool_call(tool_call, result, %{})
  end

  test "unknown aliases fail before tool execution", %{scope: scope} do
    tool_call = %{
      id: "call-1",
      name: "direct",
      arguments: %{materialization_handle: "mat_unknown"},
      action_module: DirectHandleAction
    }

    assert {:error, {:unknown_materialization_alias, "mat_unknown"}} =
             MaterializationAliases.expand_tool_call(tool_call, %{
               materialization_alias_scope: scope
             })
  end

  test "propagates unknown alias errors from list traversal", %{scope: scope} do
    tool_call = %{
      arguments: %{records: [record("unknown", "mat_unknown")]},
      action_module: LegacyNimbleAction
    }

    assert {:error, {:unknown_materialization_alias, "mat_unknown"}} =
             MaterializationAliases.expand_tool_call(tool_call, %{
               materialization_alias_scope: scope
             })
  end

  test "tools without declared handle paths do not require alias scope" do
    tool_call = %{
      id: "call-1",
      name: "noop",
      arguments: %{query: "hello"},
      action_module: NoHandleAction
    }

    assert {:ok, ^tool_call} = MaterializationAliases.expand_tool_call(tool_call, %{})

    assert {:ok, {:ok, %{answer: "hello"}, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, %{answer: "hello"}, []},
               %{}
             )
  end

  test "invalid tool calls pass through unchanged" do
    invalid = %{arguments: [], action_module: DirectHandleAction}
    assert {:ok, ^invalid} = MaterializationAliases.expand_tool_call(invalid, %{})

    missing_shape = %{arguments: %{}}
    assert {:ok, ^missing_shape} = MaterializationAliases.expand_tool_call(missing_shape, %{})
  end

  test "clearing one scope does not remove aliases from another scope", %{scope: scope} do
    other_scope = "other-scope-#{System.unique_integer([:positive])}"
    handle = handle!("other-scope")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    on_exit(fn -> MaterializationAliases.clear_scope(other_scope) end)

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("other-scope", handle)}, []},
               %{materialization_alias_scope: other_scope}
             )

    MaterializationAliases.clear_scope(scope)

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             MaterializationAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{materialization_alias_scope: other_scope}
             )
  end

  test "accepts string-keyed alias scope context", %{scope: scope} do
    handle = handle!("string-scope")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("string-scope", handle)}, []},
               %{"materialization_alias_scope" => scope}
             )

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             MaterializationAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{"materialization_alias_scope" => scope}
             )
  end

  test "requires alias scope when handle paths exist" do
    tool_call = %{
      arguments: %{materialization_handle: "mat_missing"},
      action_module: DirectHandleAction
    }

    assert {:error, :missing_materialization_alias_scope} =
             MaterializationAliases.expand_tool_call(tool_call, %{})
  end

  test "collects handles from Zoi record and record page structs", %{scope: scope} do
    handle = handle!("struct")
    alias = alias_for(scope, RecordStructAction, %{record: record("struct", handle)})

    assert {:ok, %{arguments: %{record: %Record{materialization_handle: ^handle}}}} =
             MaterializationAliases.expand_tool_call(
               %{
                 arguments: %{record: record("struct", alias)},
                 action_module: RecordStructAction
               },
               %{materialization_alias_scope: scope}
             )

    page = page([record("page", alias)])

    assert {:ok,
            {:ok, %{page: %RecordPage{records: [%Record{materialization_handle: ^alias}]}}, []}} =
             MaterializationAliases.alias_tool_result(
               %{action_module: RecordPageAction},
               {:ok, %{page: page}, []},
               %{materialization_alias_scope: scope}
             )
  end

  test "traverses explicit struct fields and arrays", %{scope: scope} do
    handles = Enum.map(["a", "b"], &handle!(&1))

    result = %{
      page:
        page(Enum.zip(["a", "b"], handles) |> Enum.map(fn {id, handle} -> record(id, handle) end))
    }

    assert {:ok, {:ok, %{page: %RecordPage{records: records}}, []}} =
             MaterializationAliases.alias_tool_result(
               %{action_module: RecordPageFieldsAction},
               {:ok, result, []},
               %{materialization_alias_scope: scope}
             )

    assert Enum.all?(records, &String.starts_with?(&1.materialization_handle, "mat_"))
  end

  test "traverses generic structs, defaults, and unions", %{scope: scope} do
    handle = handle!("generic")
    alias = alias_for(scope, DirectHandleAction, %{record: record("generic", handle)})

    wrapper_call = %{
      arguments: %{wrapper: %TestWrapper{handle: alias}},
      action_module: GenericStructAction
    }

    assert {:ok, %{arguments: %{wrapper: %TestWrapper{handle: alias}}}} =
             MaterializationAliases.expand_tool_call(wrapper_call, %{
               materialization_alias_scope: scope
             })

    call = %{
      arguments: %{default_handle: alias, union_handle: alias},
      action_module: DefaultUnionAction
    }

    assert {:ok, %{arguments: %{default_handle: ^handle, union_handle: ^handle}}} =
             MaterializationAliases.expand_tool_call(call, %{materialization_alias_scope: scope})
  end

  test "collects handles from legacy Nimble schemas", %{scope: scope} do
    handles = Enum.map(["record", "page", "list"], &handle!(&1))
    [record_handle, page_handle, list_handle] = handles

    assert {:ok, aliases} =
             MaterializationAliases.alias_tool_result(
               %{action_module: DirectHandleAction},
               {:ok, %{record: record("record", record_handle)}, []},
               %{materialization_alias_scope: scope}
             )

    record_alias =
      aliases |> elem(1) |> Map.fetch!(:record) |> Map.fetch!(:materialization_handle)

    page_alias = alias_for(scope, DirectHandleAction, %{record: record("page", page_handle)})
    list_alias = alias_for(scope, DirectHandleAction, %{record: record("list", list_handle)})

    call = %{
      arguments: %{
        record: record("record", record_alias),
        page: page([record("page", page_alias)]),
        records: [record("list", list_alias)],
        ignored: "untouched"
      },
      action_module: LegacyNimbleAction
    }

    assert {:ok, %{arguments: arguments}} =
             MaterializationAliases.expand_tool_call(call, %{materialization_alias_scope: scope})

    assert arguments.record.materialization_handle == record_handle
    assert hd(arguments.page.records).materialization_handle == page_handle
    assert hd(arguments.records).materialization_handle == list_handle
    assert arguments.ignored == "untouched"
  end

  test "no-op traversal branches preserve unmatched values", %{scope: scope} do
    tool_call = %{action_module: RecordPageFieldsAction}
    output = %{page: %{records: "not-a-list"}}

    assert {:ok, {:ok, ^output, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, output, []},
               %{materialization_alias_scope: scope}
             )

    missing = %{}

    assert {:ok, {:ok, ^missing, []}} =
             MaterializationAliases.alias_tool_result(tool_call, {:ok, missing, []}, %{
               materialization_alias_scope: scope
             })

    output = %{page: %{records: ["not-a-map"]}}

    assert {:ok, {:ok, ^output, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, output, []},
               %{materialization_alias_scope: scope}
             )
  end

  test "ignores schema paths with unsupported key types", %{scope: scope} do
    tool_call = %{
      arguments: %{record: "untouched"},
      action_module: NonStringKeyAction
    }

    assert {:ok, ^tool_call} =
             MaterializationAliases.expand_tool_call(tool_call, %{
               materialization_alias_scope: scope
             })
  end

  test "binary schema keys resolve atom arguments and ignore unknown keys", %{scope: scope} do
    handle = handle!("binary-key")
    alias = alias_for(scope, DirectHandleAction, %{record: record("binary-key", handle)})
    call = %{arguments: %{materialization_handle: alias}, action_module: BinaryKeyAction}

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             MaterializationAliases.expand_tool_call(call, %{materialization_alias_scope: scope})
  end

  test "value guards leave invalid and already aliased values unchanged", %{scope: scope} do
    for value <- [123, "plain-value"] do
      call = %{arguments: %{materialization_handle: value}, action_module: DirectHandleAction}

      assert {:ok, ^call} =
               MaterializationAliases.expand_tool_call(call, %{materialization_alias_scope: scope})
    end

    output = %{record: record("invalid", 123)}
    tool_call = %{action_module: DirectHandleAction}

    assert {:ok, {:ok, ^output, []}} =
             MaterializationAliases.alias_tool_result(tool_call, {:ok, output, []}, %{
               materialization_alias_scope: scope
             })

    already = %{record: record("existing", "mat_existing")}

    assert {:ok, {:ok, ^already, []}} =
             MaterializationAliases.alias_tool_result(tool_call, {:ok, already, []}, %{
               materialization_alias_scope: scope
             })
  end

  test "reuses the alias for a handle in the same scope", %{scope: scope} do
    handle = handle!("cached")
    tool_call = %{action_module: DirectHandleAction}
    result = {:ok, %{record: record("cached", handle)}, []}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: first}}, []}} =
             MaterializationAliases.alias_tool_result(tool_call, result, %{
               materialization_alias_scope: scope
             })

    assert {:ok, {:ok, %{record: %Record{materialization_handle: second}}, []}} =
             MaterializationAliases.alias_tool_result(tool_call, result, %{
               materialization_alias_scope: scope
             })

    assert first == second
  end

  property "aliasing and expansion round trip signed handles", %{scope: scope} do
    check all(file_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 24)) do
      handle = handle!(file_id)

      tool_call = %{
        id: "call-1",
        name: "direct",
        arguments: %{},
        action_module: DirectHandleAction
      }

      result = {:ok, %{record: record(file_id, handle)}, []}

      assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
               MaterializationAliases.alias_tool_result(tool_call, result, %{
                 materialization_alias_scope: scope
               })

      assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
               MaterializationAliases.expand_tool_call(
                 %{tool_call | arguments: %{materialization_handle: alias}},
                 %{
                   materialization_alias_scope: scope
                 }
               )
    end
  end

  defp handle!(file_id) do
    assert {:ok, handle} =
             Handle.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => file_id
             })

    handle
  end

  defp record(id, handle), do: %Record{id: id, kind: :file, materialization_handle: handle}

  defp page(records), do: %RecordPage{resource_type: :file, records: records}

  defp alias_for(scope, _action_module, %{record: record}) do
    tool_call = %{action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             MaterializationAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record}, []},
               %{materialization_alias_scope: scope}
             )

    alias
  end
end
