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
end
