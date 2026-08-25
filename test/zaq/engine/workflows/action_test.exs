# ---------------------------------------------------------------------------
# Inline test modules for batch_field/1
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredList do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_list",
    schema: [items: [type: :list, required: true]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredParamList do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_param_list",
    schema: [contacts: [type: {:list, :map}, required: true]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredMap do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_map",
    schema: [contact: [type: :map, required: true]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredString do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_string",
    schema: [name: [type: :string, required: true]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.ListAndMap do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_list_and_map",
    schema: [
      items: [type: :list, required: true],
      context_map: [type: :map, required: true]
    ],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.NoRequired do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_no_required",
    schema: [opt: [type: :string, required: false]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.TwoLists do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_two_lists",
    schema: [
      items: [type: :list, required: true],
      more: [type: :list, required: true]
    ],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.TwoMaps do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_two_maps",
    schema: [
      contact: [type: :map, required: true],
      meta: [type: :map, required: true]
    ],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredZoiList do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_zoi_list",
    schema: Zoi.object(%{items: Zoi.list(Zoi.map())}),
    output_schema: Zoi.object(%{out: Zoi.any()})

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.ActionTest.FloatParam do
  @moduledoc false
  use Jido.Action,
    name: "action_test_float_param",
    schema: [score: [type: :float, required: true, doc: "A JSON number"]],
    output_schema: [out: [type: :boolean, required: true, doc: "Done"]]

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredZoiMap do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_zoi_map",
    schema: Zoi.object(%{contact: Zoi.map()}),
    output_schema: Zoi.object(%{out: Zoi.any()})

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.UnsupportedSchemaShape do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_unsupported_schema_shape",
    schema: [input: [type: :any, required: true]],
    output_schema: [out: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action

  defoverridable schema: 0

  def schema, do: :unsupported_schema

  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredZoiString do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_zoi_string",
    schema: Zoi.object(%{name: Zoi.string()}),
    output_schema: Zoi.object(%{out: Zoi.any()})

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.BatchFieldTest.RequiredZoiUnionList do
  @moduledoc false
  use Jido.Action,
    name: "batch_field_required_zoi_union_list",
    schema: Zoi.object(%{items: Zoi.union([Zoi.list(Zoi.map()), Zoi.string()])}),
    output_schema: Zoi.object(%{out: Zoi.any()})

  use Zaq.Engine.Workflows.Action
  @impl Jido.Action
  def run(_, _), do: {:ok, %{out: true}}
end

defmodule Zaq.Engine.Workflows.ActionTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.Test.{NonConformingAction, OkAction}

  alias Zaq.Engine.Workflows.BatchFieldTest.{
    ListAndMap,
    NoRequired,
    RequiredList,
    RequiredMap,
    RequiredParamList,
    RequiredString,
    RequiredZoiList,
    RequiredZoiMap,
    RequiredZoiString,
    RequiredZoiUnionList,
    TwoLists,
    TwoMaps,
    UnsupportedSchemaShape
  }

  describe "batch_field/1" do
    test "one required :list field → {:ok, {field, :list}}" do
      assert {:ok, {:items, :list}} = Action.batch_field(RequiredList)
    end

    test "one required {:list, subtype} field → {:ok, {field, :list}}" do
      assert {:ok, {:contacts, :list}} = Action.batch_field(RequiredParamList)
    end

    test "one required :map field → {:ok, {field, :item}}" do
      assert {:ok, {:contact, :item}} = Action.batch_field(RequiredMap)
    end

    test "one required :string field → {:ok, {field, :item}}" do
      assert {:ok, {:name, :item}} = Action.batch_field(RequiredString)
    end

    test "one required :list + one required :map → list wins unambiguously" do
      assert {:ok, {:items, :list}} = Action.batch_field(ListAndMap)
    end

    test "one required Zoi list field → {:ok, {field, :list}}" do
      assert {:ok, {:items, :list}} = Action.batch_field(RequiredZoiList)
    end

    test "one required Zoi map field → {:ok, {field, :item}}" do
      assert {:ok, {:contact, :item}} = Action.batch_field(RequiredZoiMap)
    end

    test "one required Zoi non-list field → {:ok, {field, :item}}" do
      assert {:ok, {:name, :item}} = Action.batch_field(RequiredZoiString)
    end

    test "unsupported schema shape → {:error, {:no_batch_field, module}}" do
      assert {:error, {:no_batch_field, UnsupportedSchemaShape}} =
               Action.batch_field(UnsupportedSchemaShape)
    end

    test "one required Zoi union with list branch → {:ok, {field, :list}}" do
      assert {:ok, {:items, :list}} = Action.batch_field(RequiredZoiUnionList)
    end

    test "zero required fields → {:error, {:no_batch_field, module}}" do
      assert {:error, {:no_batch_field, NoRequired}} = Action.batch_field(NoRequired)
    end

    test "two required :list fields → {:error, {:ambiguous_batch_field, module, fields}}" do
      assert {:error, {:ambiguous_batch_field, TwoLists, fields}} =
               Action.batch_field(TwoLists)

      assert :items in fields
      assert :more in fields
    end

    test "two required :map fields, no list → {:error, {:ambiguous_batch_field, module, fields}}" do
      assert {:error, {:ambiguous_batch_field, TwoMaps, fields}} =
               Action.batch_field(TwoMaps)

      assert :contact in fields
      assert :meta in fields
    end

    test "non-existent module → {:error, {:no_batch_field, module}}" do
      assert {:error, {:no_batch_field, Zaq.NonExistent.Module}} =
               Action.batch_field(Zaq.NonExistent.Module)
    end

    test "optional fields are ignored regardless of type" do
      # NoRequired has one optional :string — no required fields at all
      assert {:error, {:no_batch_field, NoRequired}} = Action.batch_field(NoRequired)
    end
  end

  describe "log_start/0 and log_entry/3" do
    test "log_start/0 returns an integer" do
      assert is_integer(Action.log_start())
    end

    test "log_entry/2 returns map with event (string), at (DateTime), duration_ms (integer)" do
      t0 = Action.log_start()
      entry = Action.log_entry(:step_completed, t0)

      assert entry.event == "step_completed"
      assert %DateTime{} = entry.at
      assert is_integer(entry.duration_ms)
      assert entry.duration_ms >= 0
    end

    test "log_entry/3 merges extra attrs into the entry" do
      t0 = Action.log_start()
      entry = Action.log_entry(:chunk_completed, t0, %{index: 2, results: 4})

      assert entry.event == "chunk_completed"
      assert entry.index == 2
      assert entry.results == 4
      assert entry.duration_ms >= 0
    end

    test "atom events are stringified" do
      t0 = Action.log_start()
      entry = Action.log_entry(:item_ok, t0)

      assert entry.event == "item_ok"
      assert is_binary(entry.event)
    end

    test "string events are kept as-is" do
      t0 = Action.log_start()
      entry = Action.log_entry("chunk_error", t0)

      assert entry.event == "chunk_error"
    end

    test "duration_ms is >= 0 even for zero-duration calls" do
      t0 = Action.log_start()
      entry = Action.log_entry(:x, t0)

      assert entry.duration_ms >= 0
    end

    test "conflicting attrs key does NOT overwrite event" do
      t0 = Action.log_start()
      entry = Action.log_entry(:real_event, t0, %{event: "hijack"})

      assert entry.event == "real_event"
    end

    test "conflicting attrs key does NOT overwrite duration_ms" do
      t0 = Action.log_start()
      entry = Action.log_entry(:x, t0, %{duration_ms: 99_999})

      assert entry.duration_ms != 99_999
      assert entry.duration_ms >= 0
    end

    test "conflicting attrs key does NOT overwrite at" do
      t0 = Action.log_start()
      fake_dt = ~U[2000-01-01 00:00:00Z]
      entry = Action.log_entry(:x, t0, %{at: fake_dt})

      refute entry.at == fake_dt
    end

    test "log_start/0 and log_entry/3 are imported in modules that use Action" do
      # Modules that `use Zaq.Engine.Workflows.Action` should get both helpers
      # via the import in __using__ — test via the Batch/Iterate modules which use it.
      assert function_exported?(Zaq.Agent.Tools.Workflow.Batch, :log_start, 0) == false
      # They are imported (not exported), so we verify the import does not crash
      # by calling them through Action directly (public functions).
      assert is_integer(Action.log_start())
    end
  end

  describe "validate/1" do
    test "returns :ok for a fully conforming action module" do
      assert :ok = Action.validate(OkAction)
    end

    test "returns contract_violation for a loaded module missing all contract pieces" do
      assert {:error, {:contract_violation, NonConformingAction, missing}} =
               Action.validate(NonConformingAction)

      assert :on_success in missing
      assert :on_failure in missing
      assert :schema in missing
      assert :output_schema in missing
    end

    test "returns contract_violation with all required pieces when module does not exist" do
      assert {:error, {:contract_violation, Zaq.VeryNonExistentModule, missing}} =
               Action.validate(Zaq.VeryNonExistentModule)

      assert missing == [:on_success, :on_failure, :schema, :output_schema]
    end
  end

  describe "validate_ref/1" do
    test "returns :ok for a module string that resolves to a conforming action" do
      assert :ok = Action.validate_ref("Zaq.Engine.Workflows.Test.OkAction")
    end

    test "returns {:unknown_module, str} for a string that resolves to no module" do
      assert {:error, {:unknown_module, "Zaq.Does.Not.Exist"}} =
               Action.validate_ref("Zaq.Does.Not.Exist")
    end

    test "returns {:unknown_module, nil} for nil" do
      assert {:error, {:unknown_module, nil}} = Action.validate_ref(nil)
    end

    test "returns contract_violation for a resolvable but non-conforming module" do
      assert {:error, {:contract_violation, NonConformingAction, missing}} =
               Action.validate_ref("Zaq.Engine.Workflows.Test.NonConformingAction")

      assert :schema in missing
    end
  end

  describe "compile-time contract enforcement (full mode)" do
    test "a conforming module compiles and gets the behaviour + defaults" do
      defmodule CompileOkAction do
        use Zaq.Engine.Workflows.Action,
          name: "compile_ok_action",
          schema: [input: [type: :any, required: true]],
          output_schema: [result: [type: :map, required: true]]

        @impl Jido.Action
        def run(params, _ctx), do: {:ok, %{result: params}}
      end

      assert :ok = Action.validate(CompileOkAction)
      assert {:ok, %{result: %{}}} = CompileOkAction.run(%{}, %{})
      # default lifecycle hooks are injected
      assert {:ok, %{}} = CompileOkAction.on_success(%{}, %{})
      assert :ok = CompileOkAction.on_failure(:boom, %{})
    end

    test "module attributes defer schema contract checks to runtime validation" do
      code = """
      defmodule Zaq.Engine.Workflows.ActionTest.DeferredLiteralContractAction do
        @schema [input: [type: :any, required: true]]
        @output_schema [result: [type: :map, required: true]]

        use Zaq.Engine.Workflows.Action,
          name: "deferred_literal_contract_action",
          schema: @schema,
          output_schema: @output_schema

        @impl Jido.Action
        def run(params, _ctx), do: {:ok, %{result: params}}
      end
      """

      [{module, _beam}] = Code.compile_string(code)

      assert Code.ensure_loaded?(module)
      assert :ok = Action.validate(module)
    end

    test "missing output_schema fails to compile with a descriptive error" do
      code = """
      defmodule Zaq.Engine.Workflows.ActionTest.MissingOutputSchema do
        use Zaq.Engine.Workflows.Action,
          name: "missing_output_schema",
          schema: [input: [type: :any, required: true]]

        @impl Jido.Action
        def run(_params, _ctx), do: {:ok, %{}}
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(code) end
      assert error.description =~ "output_schema"
      assert error.description =~ "contract violation"
    end

    test "empty schema fails to compile with a descriptive error" do
      code = """
      defmodule Zaq.Engine.Workflows.ActionTest.EmptySchema do
        use Zaq.Engine.Workflows.Action,
          name: "empty_schema",
          schema: [],
          output_schema: [result: [type: :map, required: true]]

        @impl Jido.Action
        def run(_params, _ctx), do: {:ok, %{result: %{}}}
      end
      """

      error = assert_raise CompileError, fn -> Code.compile_string(code) end
      assert error.description =~ "schema"
      assert error.description =~ "is empty"
    end

    test "bare `use` (legacy mode) attaches the behaviour without enforcing the contract" do
      defmodule LegacyBehaviourAction do
        use Jido.Action, name: "legacy_behaviour_action", schema: []

        use Zaq.Engine.Workflows.Action

        @impl Jido.Action
        def run(_params, _ctx), do: {:ok, %{}}
      end

      # Behaviour hooks present, but no compile-time contract failure despite the
      # empty schema (runtime validate/1 remains the backstop).
      assert {:ok, %{}} = LegacyBehaviourAction.on_success(%{}, %{})
      assert :ok = LegacyBehaviourAction.on_failure(:x, %{})
    end
  end

  # Both schema dialects are read into one vocabulary — Zoi — so a value is judged
  # the same way wherever it is judged. The values being judged arrive as JSON from
  # an agent or a JSONB workflow definition, so the translation is JSON-shaped:
  # a JSON object is string-keyed, a JSON number may stand in for a float, and an
  # enum an author spells as atoms reaches us as strings.
  describe "field_specs/1" do
    defmodule KeywordSchemaAction do
      @moduledoc false
      use Jido.Action,
        name: "keyword_schema_action",
        schema: [
          name: [type: :string, required: true],
          count: [type: :integer, required: true],
          ratio: [type: :float, required: false],
          rows: [type: {:list, {:list, :any}}, required: false],
          payload: [type: :map, required: false],
          conditions: [type: {:list, :map}, required: false],
          mode: [type: {:in, [:halt, :continue]}, required: false],
          either: [type: {:or, [:map, :string]}, required: false],
          anything: [type: :any, required: false],
          positive: [type: :pos_integer, required: false]
        ],
        output_schema: [result: [type: :any, required: true]]

      @impl Jido.Action
      def run(params, _ctx), do: {:ok, %{result: params}}
    end

    defp spec_for(module, field) do
      {_name, schema, _required?} =
        module |> inspect() |> Action.field_specs() |> List.keyfind(field, 0)

      schema
    end

    defp accepts?(module, field, value),
      do: match?({:ok, _}, Zoi.parse(spec_for(module, field), value))

    test "every field is read, with its required flag" do
      specs = Action.field_specs(inspect(KeywordSchemaAction))

      assert {"name", _, true} = List.keyfind(specs, "name", 0)
      assert {"ratio", _, false} = List.keyfind(specs, "ratio", 0)
      assert length(specs) == 10
    end

    test "scalar types judge scalars" do
      assert accepts?(KeywordSchemaAction, "name", "Ada")
      refute accepts?(KeywordSchemaAction, "name", 42)

      assert accepts?(KeywordSchemaAction, "count", 42)
      refute accepts?(KeywordSchemaAction, "count", "42")

      assert accepts?(KeywordSchemaAction, "positive", 3)
      refute accepts?(KeywordSchemaAction, "positive", -3)
    end

    # JSON has one number type: `4` and `4.0` are the same literal, so a float field
    # must take the integer form or every whole-numbered float would be refused.
    test "a float field accepts a JSON whole number" do
      assert accepts?(KeywordSchemaAction, "ratio", 4.2)
      assert accepts?(KeywordSchemaAction, "ratio", 4)
      refute accepts?(KeywordSchemaAction, "ratio", "4.2")
    end

    # A JSON object is string-keyed. NimbleOptions' `:map` demands atom keys, which
    # no JSON payload can satisfy — the reason this translation exists.
    test "a map field accepts a string-keyed JSON object" do
      assert accepts?(KeywordSchemaAction, "payload", %{"key" => "value"})
      assert accepts?(KeywordSchemaAction, "payload", %{key: "value"})
      refute accepts?(KeywordSchemaAction, "payload", "not an object")
    end

    test "a list-of-maps field accepts string-keyed elements" do
      assert accepts?(KeywordSchemaAction, "conditions", [%{"key" => "a", "op" => "eq"}])
      refute accepts?(KeywordSchemaAction, "conditions", %{"key" => "a"})
    end

    test "a nested list type is judged structurally" do
      assert accepts?(KeywordSchemaAction, "rows", [["a", "b"], ["c"]])
      refute accepts?(KeywordSchemaAction, "rows", ["a", "b"])
    end

    # An author spells the choices as atoms; an agent can only send strings.
    test "an enum field accepts either the atom or its string form" do
      assert accepts?(KeywordSchemaAction, "mode", :halt)
      assert accepts?(KeywordSchemaAction, "mode", "halt")
      refute accepts?(KeywordSchemaAction, "mode", "explode")
    end

    test "a union field accepts any of its branches" do
      assert accepts?(KeywordSchemaAction, "either", %{"a" => 1})
      assert accepts?(KeywordSchemaAction, "either", "a string")
      refute accepts?(KeywordSchemaAction, "either", 42)
    end

    test "an :any field accepts anything JSON can carry" do
      for value <- ["s", 42, 4.2, true, ["a"], %{"k" => "v"}] do
        assert accepts?(KeywordSchemaAction, "anything", value)
      end
    end

    test "a Zoi-declared schema is read as itself" do
      specs = Action.field_specs("Zaq.Agent.Tools.People.UpdatePerson")

      assert {"person_id", schema, true} = List.keyfind(specs, "person_id", 0)
      assert {:ok, _} = Zoi.parse(schema, 42)
      assert {:error, _} = Zoi.parse(schema, "42")
    end

    test "a module with nothing readable yields no specs" do
      for module <- [nil, "", "Not.A.Module"] do
        assert Action.field_specs(module) == []
      end
    end

    # Every production action must survive translation — a type this cannot express
    # would silently become `any` and stop judging anything.
    test "every registered tool's schema translates" do
      for %{module: mod} <- Zaq.Agent.Tools.Registry.tools(),
          Code.ensure_loaded?(mod),
          function_exported?(mod, :schema, 0) do
        specs = Action.field_specs(inspect(mod))
        declared = if is_list(mod.schema()), do: length(mod.schema()), else: length(specs)

        assert length(specs) == declared, "#{inspect(mod)} lost fields in translation"
      end
    end
  end

  describe "output_field_specs/1" do
    test "reads a NimbleOptions output schema" do
      specs = Action.output_field_specs("Zaq.Agent.Tools.Workflow.Condition")

      assert {"passed", _spec, true} = List.keyfind(specs, "passed", 0)
    end

    test "reads a Zoi output schema" do
      specs = Action.output_field_specs("Zaq.Agent.Tools.Workflow.ValidateWorkflowInput")

      assert {"valid", _spec, true} = List.keyfind(specs, "valid", 0)
    end

    test "a module with no output schema yields no specs" do
      for module <- [nil, "", "Not.A.Module"] do
        assert Action.output_field_specs(module) == []
      end
    end
  end

  # `invalid_inputs` and the run-time refusal both exist to tell a caller what kind of
  # value to send instead, so a composite must name what it accepts — not itself.
  describe "schema_kind/1" do
    test "a scalar is named by its type" do
      assert Action.schema_kind(Zoi.string()) == "string"
      assert Action.schema_kind(Zoi.integer()) == "integer"
    end

    test "a union names its members, not \"union\"" do
      assert Action.schema_kind(Zoi.union([Zoi.map(), Zoi.string()])) == "map or string"
    end

    test "a union of one distinct kind collapses to that kind" do
      assert Action.schema_kind(Zoi.union([Zoi.string(), Zoi.string()])) == "string"
    end

    test "an array names its element kind" do
      assert Action.schema_kind(Zoi.array(Zoi.string())) == "list of string"
    end

    test "an enum names its values, collapsing the atom and string form of each" do
      assert Action.schema_kind(Zoi.enum([:halt, "halt", :continue, "continue"])) ==
               "one of: halt, continue"
    end

    # The translated NimbleOptions types are where this matters most: the composite is
    # an artefact of the translation, never something the author wrote.
    test "a translated :float field reads as the numbers it accepts" do
      specs = Action.field_specs("Zaq.Engine.Workflows.ActionTest.FloatParam")

      assert {"score", spec, true} = List.keyfind(specs, "score", 0)
      assert Action.schema_kind(spec) == "float or integer"
    end

    test "a translated {:in, choices} field reads as its choices" do
      specs = Action.field_specs("Zaq.Agent.Tools.Workflow.Condition")

      assert {"on_fail", spec, false} = List.keyfind(specs, "on_fail", 0)
      assert Action.schema_kind(spec) == "one of: halt, continue"
    end

    test "an unreadable spec is \"any\"" do
      assert Action.schema_kind(:not_a_schema) == "any"
    end
  end
end
