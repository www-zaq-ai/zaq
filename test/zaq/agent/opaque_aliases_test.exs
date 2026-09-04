defmodule Zaq.Agent.OpaqueAliasesTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Jido.AI.Turn
  alias Zaq.Agent.{Factory, OpaqueAliases}
  alias Zaq.Agent.Tools.DataSource.{DeleteDocument, SearchDocuments}
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Contracts.Record.Provenance
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

  defmodule DirectHandleAndRecordAction do
    def schema do
      Zoi.object(%{
        materialization_handle: Handle.zoi_type(),
        record: Record.zoi_type()
      })
    end
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
    OpaqueAliases.clear_scope(scope)
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
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
             OpaqueAliases.alias_tool_result(tool_call, result, %{
               opaque_alias_scope: scope
             })

    assert String.starts_with?(alias, "mat_")

    aliased_call = %{tool_call | arguments: %{"materialization_handle" => alias, "note" => alias}}

    assert {:ok, expanded} =
             OpaqueAliases.expand_tool_call(aliased_call, %{
               opaque_alias_scope: scope
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
             Factory.after_tool_call(tool_call, result, %{opaque_alias_scope: scope})

    assert [
             %Record{materialization_handle: first_alias},
             %Record{materialization_handle: second_alias}
           ] =
             records

    assert String.starts_with?(first_alias, "mat_")
    assert String.starts_with?(second_alias, "mat_")
    refute first_alias == second_alias
  end

  test "aliases and expands provenance tokens on record paths", %{scope: scope} do
    handle = handle!("file-1")
    provenance = provenance!("file-1")
    output_record = record("file-1", handle, provenance)

    tool_call = %{id: "call-1", name: "direct", arguments: %{}, action_module: DirectHandleAction}

    assert {:ok,
            {:ok,
             %{
               record: %Record{
                 materialization_handle: materialization_alias,
                 provenance_ref: provenance_alias
               }
             }, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: output_record}, []},
               %{opaque_alias_scope: scope}
             )

    assert String.starts_with?(materialization_alias, "mat_")
    assert String.starts_with?(provenance_alias, "prov_")

    input_call = %{
      arguments: %{record: record("file-1", materialization_alias, provenance_alias)},
      action_module: RecordStructAction
    }

    assert {:ok,
            %{
              arguments: %{
                record: %Record{
                  materialization_handle: ^handle,
                  provenance_ref: ^provenance
                }
              }
            }} =
             OpaqueAliases.expand_tool_call(input_call, %{
               opaque_alias_scope: scope
             })
  end

  test "search document provenance refs survive model turn formatting for delete validation", %{
    scope: scope
  } do
    {:ok, output_record} =
      %{
        record("file-1", nil, nil)
        | parent_id: "parent-1",
          parent_ids: ["parent-1"],
          modified_at: ~U[2026-08-27 10:19:18Z],
          attributes: %{"provider_record_id" => "file-1"}
      }
      |> Provenance.seal()

    provenance = output_record.provenance_ref

    assert {:ok,
            transformed_result =
              {:ok, %RecordPage{records: [%Record{provenance_ref: provenance_alias}]}, []}} =
             OpaqueAliases.alias_tool_result(
               %{action_module: SearchDocuments},
               {:ok, %RecordPage{resource_type: :item, records: [output_record]}, []},
               %{opaque_alias_scope: scope}
             )

    assert String.starts_with?(provenance_alias, "prov_")

    assert {:ok, model_record} =
             transformed_result
             |> Turn.format_tool_result_content()
             |> Jason.decode!()
             |> get_in(["result", "records", Access.at(0)])
             |> then(&{:ok, &1})

    assert model_record["provenance_ref"] == provenance_alias
    refute model_record["provenance_ref"] == "[REDACTED]"

    model_record =
      model_record
      |> Map.delete("parent_ids")
      |> Map.put("modified_at", %{
        "__struct__" => "DateTime",
        "year" => 2026,
        "month" => 8,
        "day" => 27
      })

    tool_call = %{
      arguments: %{record: model_record},
      action_module: DeleteDocument
    }

    assert {:ok, %{arguments: %{record: %{} = arguments_record} = arguments}} =
             OpaqueAliases.expand_tool_call(tool_call, %{
               opaque_alias_scope: scope
             })

    assert arguments_record["provenance_ref"] == provenance

    assert {:ok, %{record: %Record{provenance_ref: ^provenance}}} =
             Zoi.parse(DeleteDocument.schema(), arguments)
  end

  test "propagates missing alias scope errors through the Factory interceptor" do
    tool_call = %{id: "call-1", name: "direct", arguments: %{}, action_module: DirectHandleAction}
    result = {:ok, %{record: record("file-1", handle!("file-1"))}, []}

    assert {:error, :missing_opaque_alias_scope} =
             Factory.after_tool_call(tool_call, result, %{})
  end

  test "unknown aliases fail before tool execution", %{scope: scope} do
    tool_call = %{
      id: "call-1",
      name: "direct",
      arguments: %{materialization_handle: "mat_unknown"},
      action_module: DirectHandleAction
    }

    assert {:error, {:unknown_opaque_alias, "mat_unknown"}} =
             OpaqueAliases.expand_tool_call(tool_call, %{
               opaque_alias_scope: scope
             })
  end

  test "unknown provenance aliases fail before tool execution", %{scope: scope} do
    tool_call = %{
      arguments: %{record: record("unknown", nil, "prov_unknown")},
      action_module: RecordStructAction
    }

    assert {:error, {:unknown_opaque_alias, "prov_unknown"}} =
             OpaqueAliases.expand_tool_call(tool_call, %{
               opaque_alias_scope: scope
             })
  end

  test "propagates unknown alias errors from list traversal", %{scope: scope} do
    tool_call = %{
      arguments: %{records: [record("unknown", "mat_unknown")]},
      action_module: LegacyNimbleAction
    }

    assert {:error, {:unknown_opaque_alias, "mat_unknown"}} =
             OpaqueAliases.expand_tool_call(tool_call, %{
               opaque_alias_scope: scope
             })
  end

  test "tools without declared handle paths do not require alias scope" do
    tool_call = %{
      id: "call-1",
      name: "noop",
      arguments: %{query: "hello"},
      action_module: NoHandleAction
    }

    assert {:ok, ^tool_call} = OpaqueAliases.expand_tool_call(tool_call, %{})

    assert {:ok, {:ok, %{answer: "hello"}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{answer: "hello"}, []},
               %{}
             )
  end

  test "invalid tool calls pass through unchanged" do
    invalid = %{arguments: [], action_module: DirectHandleAction}
    assert {:ok, ^invalid} = OpaqueAliases.expand_tool_call(invalid, %{})

    missing_shape = %{arguments: %{}}
    assert {:ok, ^missing_shape} = OpaqueAliases.expand_tool_call(missing_shape, %{})
  end

  test "clearing one scope does not remove aliases from another scope", %{scope: scope} do
    other_scope = "other-scope-#{System.unique_integer([:positive])}"
    handle = handle!("other-scope")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    on_exit(fn -> OpaqueAliases.clear_scope(other_scope) end)

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("other-scope", handle)}, []},
               %{opaque_alias_scope: other_scope}
             )

    OpaqueAliases.clear_scope(scope)

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             OpaqueAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{opaque_alias_scope: other_scope}
             )
  end

  test "aliases cannot be expanded from another scope", %{scope: scope} do
    other_scope = "cross-scope-#{System.unique_integer([:positive])}"
    handle = handle!("cross-scope")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    on_exit(fn -> OpaqueAliases.clear_scope(other_scope) end)

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("cross-scope", handle)}, []},
               %{opaque_alias_scope: scope}
             )

    assert {:error, {:unknown_opaque_alias, ^alias}} =
             OpaqueAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{opaque_alias_scope: other_scope}
             )
  end

  test "cleared scope aliases are rejected before tool execution", %{scope: scope} do
    handle = handle!("expired")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("expired", handle)}, []},
               %{opaque_alias_scope: scope}
             )

    OpaqueAliases.clear_scope(scope)

    assert {:error, {:unknown_opaque_alias, ^alias}} =
             OpaqueAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{opaque_alias_scope: scope}
             )
  end

  test "multiple aliases expand only to their originating handles", %{scope: scope} do
    first = handle!("multi-a")
    second = handle!("multi-b")

    result =
      {:ok,
       %{
         records: [
           record("multi-a", first),
           record("multi-b", second)
         ]
       }, []}

    assert {:ok, {:ok, %{records: records}, []}} =
             Factory.after_tool_call(
               %{arguments: %{}, action_module: RecordListAction},
               result,
               %{opaque_alias_scope: scope}
             )

    [%Record{materialization_handle: first_alias}, %Record{materialization_handle: second_alias}] =
      records

    refute first_alias == second_alias

    assert {:ok, %{arguments: %{materialization_handle: ^first}}} =
             Factory.before_tool_call(
               %{
                 arguments: %{materialization_handle: first_alias},
                 action_module: DirectHandleAction
               },
               %{opaque_alias_scope: scope}
             )

    assert {:ok, %{arguments: %{materialization_handle: ^second}}} =
             Factory.before_tool_call(
               %{
                 arguments: %{materialization_handle: second_alias},
                 action_module: DirectHandleAction
               },
               %{opaque_alias_scope: scope}
             )
  end

  test "accepts string-keyed alias scope context", %{scope: scope} do
    handle = handle!("string-scope")
    tool_call = %{arguments: %{}, action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record("string-scope", handle)}, []},
               %{"opaque_alias_scope" => scope}
             )

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             OpaqueAliases.expand_tool_call(
               %{tool_call | arguments: %{materialization_handle: alias}},
               %{"opaque_alias_scope" => scope}
             )
  end

  test "requires alias scope when handle paths exist" do
    tool_call = %{
      arguments: %{materialization_handle: "mat_missing"},
      action_module: DirectHandleAction
    }

    assert {:error, :missing_opaque_alias_scope} =
             OpaqueAliases.expand_tool_call(tool_call, %{})
  end

  test "collects handles from Zoi record and record page structs", %{scope: scope} do
    handle = handle!("struct")
    alias = alias_for(scope, RecordStructAction, %{record: record("struct", handle)})

    assert {:ok, %{arguments: %{record: %Record{materialization_handle: ^handle}}}} =
             OpaqueAliases.expand_tool_call(
               %{
                 arguments: %{record: record("struct", alias)},
                 action_module: RecordStructAction
               },
               %{opaque_alias_scope: scope}
             )

    page = page([record("page", alias)])

    assert {:ok,
            {:ok, %{page: %RecordPage{records: [%Record{materialization_handle: ^alias}]}}, []}} =
             OpaqueAliases.alias_tool_result(
               %{action_module: RecordPageAction},
               {:ok, %{page: page}, []},
               %{opaque_alias_scope: scope}
             )
  end

  test "traverses explicit struct fields and arrays", %{scope: scope} do
    handles = Enum.map(["a", "b"], &handle!(&1))

    result = %{
      page:
        page(Enum.zip(["a", "b"], handles) |> Enum.map(fn {id, handle} -> record(id, handle) end))
    }

    assert {:ok, {:ok, %{page: %RecordPage{records: records}}, []}} =
             OpaqueAliases.alias_tool_result(
               %{action_module: RecordPageFieldsAction},
               {:ok, result, []},
               %{opaque_alias_scope: scope}
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
             OpaqueAliases.expand_tool_call(wrapper_call, %{
               opaque_alias_scope: scope
             })

    call = %{
      arguments: %{default_handle: alias, union_handle: alias},
      action_module: DefaultUnionAction
    }

    assert {:ok, %{arguments: %{default_handle: ^handle, union_handle: ^handle}}} =
             OpaqueAliases.expand_tool_call(call, %{opaque_alias_scope: scope})
  end

  test "collects handles from legacy Nimble schemas", %{scope: scope} do
    handles = Enum.map(["record", "page", "list"], &handle!(&1))
    [record_handle, page_handle, list_handle] = handles

    assert {:ok, aliases} =
             OpaqueAliases.alias_tool_result(
               %{action_module: DirectHandleAction},
               {:ok, %{record: record("record", record_handle)}, []},
               %{opaque_alias_scope: scope}
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
             OpaqueAliases.expand_tool_call(call, %{opaque_alias_scope: scope})

    assert arguments.record.materialization_handle == record_handle
    assert hd(arguments.page.records).materialization_handle == page_handle
    assert hd(arguments.records).materialization_handle == list_handle
    assert arguments.ignored == "untouched"
  end

  test "no-op traversal branches preserve unmatched values", %{scope: scope} do
    tool_call = %{action_module: RecordPageFieldsAction}
    output = %{page: %{records: "not-a-list"}}

    assert {:ok, {:ok, ^output, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, output, []},
               %{opaque_alias_scope: scope}
             )

    missing = %{}

    assert {:ok, {:ok, ^missing, []}} =
             OpaqueAliases.alias_tool_result(tool_call, {:ok, missing, []}, %{
               opaque_alias_scope: scope
             })

    output = %{page: %{records: ["not-a-map"]}}

    assert {:ok, {:ok, ^output, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, output, []},
               %{opaque_alias_scope: scope}
             )
  end

  test "ignores schema paths with unsupported key types", %{scope: scope} do
    tool_call = %{
      arguments: %{record: "untouched"},
      action_module: NonStringKeyAction
    }

    assert {:ok, ^tool_call} =
             OpaqueAliases.expand_tool_call(tool_call, %{
               opaque_alias_scope: scope
             })
  end

  test "binary schema keys resolve atom arguments and ignore unknown keys", %{scope: scope} do
    handle = handle!("binary-key")
    alias = alias_for(scope, DirectHandleAction, %{record: record("binary-key", handle)})
    call = %{arguments: %{materialization_handle: alias}, action_module: BinaryKeyAction}

    assert {:ok, %{arguments: %{materialization_handle: ^handle}}} =
             OpaqueAliases.expand_tool_call(call, %{opaque_alias_scope: scope})
  end

  test "value guards leave invalid and already aliased values unchanged", %{scope: scope} do
    for value <- [123, "plain-value"] do
      call = %{arguments: %{materialization_handle: value}, action_module: DirectHandleAction}

      assert {:ok, ^call} =
               OpaqueAliases.expand_tool_call(call, %{opaque_alias_scope: scope})
    end

    output = %{record: record("invalid", 123)}
    tool_call = %{action_module: DirectHandleAction}

    assert {:ok, {:ok, ^output, []}} =
             OpaqueAliases.alias_tool_result(tool_call, {:ok, output, []}, %{
               opaque_alias_scope: scope
             })

    already = %{record: record("existing", "mat_existing")}

    assert {:ok, {:ok, ^already, []}} =
             OpaqueAliases.alias_tool_result(tool_call, {:ok, already, []}, %{
               opaque_alias_scope: scope
             })
  end

  test "reuses the alias for a handle in the same scope", %{scope: scope} do
    handle = handle!("cached")
    tool_call = %{action_module: DirectHandleAction}
    result = {:ok, %{record: record("cached", handle)}, []}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: first}}, []}} =
             OpaqueAliases.alias_tool_result(tool_call, result, %{
               opaque_alias_scope: scope
             })

    assert {:ok, {:ok, %{record: %Record{materialization_handle: second}}, []}} =
             OpaqueAliases.alias_tool_result(tool_call, result, %{
               opaque_alias_scope: scope
             })

    assert first == second
  end

  property "aliasing and expansion round trip signed handles and provenance tokens", %{
    scope: scope
  } do
    check all(file_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 24)) do
      handle = handle!(file_id)
      provenance = provenance!(file_id)

      tool_call = %{
        id: "call-1",
        name: "direct",
        arguments: %{},
        action_module: DirectHandleAction
      }

      result = {:ok, %{record: record(file_id, handle, provenance)}, []}

      assert {:ok,
              {:ok,
               %{
                 record: %Record{
                   materialization_handle: handle_alias,
                   provenance_ref: provenance_alias
                 }
               }, []}} =
               OpaqueAliases.alias_tool_result(tool_call, result, %{
                 opaque_alias_scope: scope
               })

      assert {:ok,
              %{
                arguments: %{
                  materialization_handle: ^handle,
                  record: %Record{provenance_ref: ^provenance}
                }
              }} =
               OpaqueAliases.expand_tool_call(
                 %{
                   tool_call
                   | arguments: %{
                       materialization_handle: handle_alias,
                       record: record(file_id, nil, provenance_alias)
                     },
                     action_module: DirectHandleAndRecordAction
                 },
                 %{
                   opaque_alias_scope: scope
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

  defp provenance!(file_id) do
    record = %Record{id: file_id, kind: :file}
    assert {:ok, sealed} = Provenance.seal(record)
    sealed.provenance_ref
  end

  defp record(id, handle, provenance \\ nil),
    do: %Record{id: id, kind: :file, materialization_handle: handle, provenance_ref: provenance}

  defp page(records), do: %RecordPage{resource_type: :file, records: records}

  defp alias_for(scope, _action_module, %{record: record}) do
    tool_call = %{action_module: DirectHandleAction}

    assert {:ok, {:ok, %{record: %Record{materialization_handle: alias}}, []}} =
             OpaqueAliases.alias_tool_result(
               tool_call,
               {:ok, %{record: record}, []},
               %{opaque_alias_scope: scope}
             )

    alias
  end
end
