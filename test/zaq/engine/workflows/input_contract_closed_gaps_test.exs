defmodule Zaq.Engine.Workflows.InputContractClosedGapsTest do
  @moduledoc """
  Regression guards for the input-contract gaps that have been closed.

  Each of these was once a defect that made `valid?` misleading, and each assertion
  is the behaviour that replaced it. They are written from the caller's side rather
  than against the fix, so a later refactor that reopens the hole fails here.

  Two were in the declaration layer (`Action.field_specs/1` reading a schema) and two
  in `InputContract` itself. The `describe` names say which, because that is what
  decides where a regression would need fixing.

  **Two gaps remain open** and are deliberately not tested here — they need a design
  decision about what `valid?` means, not an implementation. They are written up in
  `docs/exec-plans/review/pr-696-open-gaps.md`.

  The graph and its actions come from `Zaq.Engine.Workflows.Test.ShipmentActions`, so
  this file reads no fixture file and no module from `lib/zaq/agent/tools/`.
  """
  use Zaq.DataCase, async: false

  import Zaq.InputContractHelpers

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.ShipmentActions

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    {:ok, workflow} = Workflows.import_workflow(ShipmentActions.graph())

    %{workflow: workflow}
  end

  defp payload(extra \\ %{}) do
    Map.merge(
      %{
        "reference_code" => "ABC-1234",
        "label" => "Pallet-01",
        "quantity" => 12,
        "weight_kg" => 3.5,
        "notify_email" => "ops@example.com",
        "channel" => "email",
        "customer_name" => "Acme Logistics",
        "profile" => %{"region" => "emea", "fragile" => true}
      },
      extra
    )
  end

  defp node(name, module, params \\ %{}),
    do: %{"name" => name, "module" => module, "params" => params}

  # ── Declaration layer — Action.field_specs/1 ────────────────────────────────

  describe "closed (Action): nested keys inside a structured Zoi.object" do
    # `Zoi.object` declares atom keys and defaults to `unrecognized_keys: :strip`, so a
    # string-keyed map — the only shape a JSON trigger payload has — is stripped to
    # `%{}` and the parse succeeds on nothing. Fix in `Action.field_specs/1` so the
    # contract and `StepRunner` move together.
    test "a nested value that breaks its declared rule is caught", %{workflow: workflow} do
      bogus = payload(%{"profile" => %{"region" => "not-a-region", "fragile" => true}})

      verdict = InputContract.contract(workflow, bogus)

      refute verdict.valid?, "a string-keyed nested map was never judged"
      assert %{code: :invalid_enum_value} = error_at(verdict, ["profile", "region"])
    end

    test "the same value atom-keyed already is caught, which isolates the cause", %{
      workflow: workflow
    } do
      bogus = payload(%{"profile" => %{region: "not-a-region", fragile: true}})

      assert %{code: :invalid_enum_value} =
               workflow |> InputContract.contract(bogus) |> error_at(["profile", "region"])
    end
  end

  describe "closed (Action): a whole number satisfies a Zoi.float field" do
    # `field_specs/1` promises a JSON-shaped translation because JSON has one number
    # type, and delivers it only for NimbleOptions (`zoi_type(:float)` builds a
    # `float | integer` union). A field written as `Zoi.float()` gets no such treatment.
    test "an integer weight is accepted, since JSON cannot express 3.0", %{
      workflow: workflow
    } do
      assert InputContract.contract(workflow, payload(%{"weight_kg" => 3})).valid?,
             "Zoi.float() refused a whole number that JSON cannot spell any other way"
    end
  end

  # ── InputContract layer — graph facts it has and discards ───────────────────

  describe "closed (InputContract): an iteration collection is typed" do
    # `Batch` declares no `schema/0`, so `iterated_field/1` states the need with
    # `expects: nil`. A scalar then passes the contract, and `extract_items/6` calls
    # `List.wrap/1` — so the run does not fail, it silently fans out over one element.
    setup do
      graph = %{
        "nodes" => [
          node("b", "Zaq.Agent.Tools.Workflow.Batch", %{
            "over" => "items",
            "body" => [node("s", "Zaq.Agent.Tools.Workflow.Concat")]
          })
        ],
        "edges" => [%{"from" => "start", "to" => "b", "mapping" => %{"items" => "start.rows"}}]
      }

      %{graph: graph}
    end

    test "the collection is typed as a list, not as any", %{graph: graph} do
      assert InputContract.input_types(graph)["rows"] =~ "list"
    end

    test "a scalar where a collection is required is refused", %{graph: graph} do
      verdict = InputContract.contract(graph, %{"rows" => "not a list at all"})

      refute verdict.valid?, "a scalar was accepted, and List.wrap/1 will batch it as one item"
    end
  end

  describe "closed (InputContract): two contracts no longer share one name" do
    # `contract/2` used to accept a bare list too, skipping type checking entirely and
    # treating every path as required — a weaker answer with nothing to signal that it
    # was weaker. The weaker question now has its own name, so a caller chooses it.
    test "contract/2 no longer accepts a bare list", %{workflow: workflow} do
      assert_raise FunctionClauseError, fn ->
        InputContract.contract(InputContract.required_inputs(workflow), payload())
      end
    end

    test "a present but wrong-typed value is refused, not counted as supplied", %{
      workflow: workflow
    } do
      bad = payload(%{"quantity" => "twelve"})

      # The path is present, so this is not a presence gap — the contract still refuses
      # it on the declared type.
      refute InputContract.contract(workflow, bad).valid?
    end
  end
end
