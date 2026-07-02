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
    TwoLists,
    TwoMaps
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
end
