defmodule Zaq.Engine.Workflows.ValidateIntegerInputFixtureTest do
  @moduledoc """
  Pins `validate_integer_input.json` — the fixture that demonstrates the typed input
  contract on the smallest graph that can show every case at once.

  Required, and typed:

    * `person_id` — `Zoi.integer()` (`UpdatePerson`, Zoi dialect)
    * `sequence`  — `type: :integer` (`Increment`, NimbleOptions dialect)

  Required, and untyped:

    * `name` — reached only through an interpolated placeholder, so no schema can
      type it and both ends stay presence-only

  Optional, and typed — one per wiring mechanism, because the two reach the field by
  different routes and a contract that only handled one would look correct:

    * `merge_with_person_id` — `Zoi.integer()`, wired as a lone `{{start.…}}` param
    * `separator`            — a string on `Concat`, wired by an edge mapping

  Optional means the payload may omit it, never that any value will do: both are
  type-checked when supplied, and neither is ever reported missing.

  A fixture with no consumer drifts, and this one is a worked example people will
  copy. Both ends are asserted: the contract before dispatch, and a real run.
  """
  use Zaq.DataCase, async: false

  import Zaq.InputContractHelpers

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.UseCaseFixtures

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    {:ok, workflow} = UseCaseFixtures.import_fixture("validate_integer_input.json")
    {:ok, person} = People.create_person(%{full_name: "Ada", email: "ada@example.com"})

    # `merge_with_person_id` names a *different* person — merging one with itself is a
    # domain error, not a contract one, and would say nothing about either.
    {:ok, other} = People.create_person(%{full_name: "Grace", email: "grace@example.com"})

    %{workflow: workflow, person: person, other: other}
  end

  # Only the required paths. Each optional one is added by the test that means to
  # send it, so "omitted" is the default the rest of the file runs against.
  defp payload(person, extra) do
    Map.merge(
      %{"person_id" => person.id, "sequence" => 1, "name" => "Ada"},
      extra
    )
  end

  defp run(workflow, person, payload) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => %{},
        "actor" => %{"person" => %{"id" => person.id}},
        "assigns" => %{"trigger_type" => "manual", "input" => payload, "machine" => true},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = Workflows.WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(finished.id)}
  end

  describe "the contract it demonstrates" do
    test "asks for three paths and offers two more", %{workflow: workflow} do
      assert InputContract.required_inputs(workflow) ==
               ["name", "person_id", "sequence"]

      assert InputContract.optional_inputs(workflow) == ["merge_with_person_id", "separator"]

      # Typed covers both lists: an optional field is typed like any other, because
      # the step validates every declared field it is handed a value for.
      assert workflow |> InputContract.expectations() |> Map.keys() |> Enum.sort() ==
               ["merge_with_person_id", "person_id", "separator", "sequence"]
    end

    # Regression cover for a real misleading answer: asked what this workflow expects,
    # an agent reported `merge_with_person_id` as a string and offered an example
    # payload built around that — a payload the workflow rejects. Nothing in the
    # verdict typed the path, so it guessed from the name. Every path carries its kind
    # now, so there is nothing left to guess at.
    test "every path carries its declared kind", %{workflow: workflow} do
      assert InputContract.input_types(workflow) == %{
               "name" => "any",
               "person_id" => "integer",
               "sequence" => "integer",
               "merge_with_person_id" => "integer",
               "separator" => "string"
             }
    end

    # `any` is an answer, not a gap. Leaving the untyped path out is what invites a
    # reader to supply a type for it.
    test "the untyped path is reported as any, not omitted", %{workflow: workflow} do
      types = InputContract.input_types(workflow)

      assert Map.fetch(types, "name") == {:ok, "any"}

      # `Map.keys/1` ordering is not guaranteed, so compare as a set.
      assert Enum.sort(Map.keys(types) -- InputContract.required_inputs(workflow)) ==
               ["merge_with_person_id", "separator"]
    end

    # The skeleton is what a caller fills in, so it names only what is owed.
    test "the shape asks for the required paths only", %{workflow: workflow} do
      assert InputContract.required_input_shape(workflow) == %{
               "name" => nil,
               "person_id" => nil,
               "sequence" => nil
             }
    end

    test "a correctly-typed payload is valid", %{workflow: workflow, person: person} do
      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload(person, %{}))
    end

    test "a Zoi-declared integer refuses a string", %{workflow: workflow, person: person} do
      assert %{valid?: false, errors: [violation]} =
               InputContract.contract(workflow, payload(person, %{"person_id" => "42"}))

      assert violation == %{
               path: ["person_id"],
               code: :invalid_type,
               message: "expected integer, got string"
             }
    end

    test "a NimbleOptions-declared integer refuses a string too", %{
      workflow: workflow,
      person: person
    } do
      assert %{valid?: false, errors: [violation]} =
               InputContract.contract(workflow, payload(person, %{"sequence" => "1"}))

      assert violation == %{
               path: ["sequence"],
               code: :invalid_type,
               message: "expected integer, got string"
             }
    end

    # `name` only ever reaches a field interpolated into a larger string, which
    # resolves to a string whatever the payload held — so no type is claimed for it.
    test "the untyped path takes a value of any kind", %{workflow: workflow, person: person} do
      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload(person, %{"name" => 99}))
    end

    test "null is missing, not invalid", %{workflow: workflow, person: person} do
      assert %{valid?: false, errors: [%{code: :required, path: ["person_id"]}]} =
               InputContract.contract(workflow, payload(person, %{"person_id" => nil}))
    end
  end

  describe "the optional paths it demonstrates" do
    test "omitting both is valid", %{workflow: workflow, person: person} do
      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload(person, %{}))
    end

    test "supplying both correctly is valid", %{workflow: workflow, person: person} do
      extra = %{"merge_with_person_id" => 7, "separator" => " — "}

      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload(person, extra))
    end

    # Optional forgives absence, not the wrong kind of value.
    test "the lone-placeholder optional is type-checked when supplied", %{
      workflow: workflow,
      person: person
    } do
      assert %{valid?: false, errors: [violation]} =
               InputContract.contract(
                 workflow,
                 payload(person, %{"merge_with_person_id" => "7"})
               )

      assert violation.path == ["merge_with_person_id"]
      assert violation.message == "expected integer, got string"
    end

    test "the edge-mapped optional is type-checked when supplied", %{
      workflow: workflow,
      person: person
    } do
      assert %{valid?: false, errors: [violation]} =
               InputContract.contract(workflow, payload(person, %{"separator" => 5}))

      assert violation.path == ["separator"]
      assert violation.message == "expected string, got integer"
    end

    test "a wrong-kinded optional is never reported missing", %{
      workflow: workflow,
      person: person
    } do
      extra = %{"merge_with_person_id" => "7", "separator" => 5}

      assert %{errors: violations} =
               InputContract.contract(workflow, payload(person, extra))

      assert Enum.map(violations, & &1.path) == [["merge_with_person_id"], ["separator"]]
    end
  end

  describe "the run agrees with the contract" do
    test "the valid payload runs every step", %{workflow: workflow, person: person} do
      {finished, step_runs} = run(workflow, person, payload(person, %{}))

      assert finished.status == "completed"

      completed = for s <- step_runs, s.status == "completed", do: s.step_name
      assert "update_person" in completed
      assert "bump_sequence" in completed
      assert "summarize" in completed
    end

    # The half a contract-only assertion cannot reach. An omitted optional wired as a
    # lone `{{start.…}}` used to resolve to `""` and be refused by its integer field —
    # the contract cleared a payload the run rejected. Both optionals are omitted by
    # the payload above, so this pins that an omission really is an omission.
    test "omitting the optionals leaves the step no param to refuse", %{
      workflow: workflow,
      person: person
    } do
      {_finished, step_runs} = run(workflow, person, payload(person, %{}))

      refute Enum.any?(step_runs, fn s ->
               is_binary(s.errors["reason"]) and s.errors["reason"] =~ "Invalid parameters"
             end)
    end

    test "supplying both optionals runs every step", %{
      workflow: workflow,
      person: person,
      other: other
    } do
      extra = %{"merge_with_person_id" => other.id, "separator" => " — "}
      {finished, _step_runs} = run(workflow, person, payload(person, extra))

      assert finished.status == "completed"
    end

    test "the run refuses a wrong-kinded optional in the same words", %{
      workflow: workflow,
      person: person
    } do
      payload = payload(person, %{"separator" => 5})

      assert %{errors: [%{message: message}]} =
               InputContract.contract(workflow, payload)

      {finished, step_runs} = run(workflow, person, payload)

      assert finished.status == "failed"
      failed = Enum.find(step_runs, &(&1.status == "failed"))
      assert failed.step_name == "summarize"
      assert failed.errors["reason"] == "Invalid parameters: separator: " <> message
    end

    # The second half of the guarantee: a payload that bypasses the pre-flight check
    # is still refused, by the step whose schema the value contradicts.
    test "a wrong-typed integer fails the step that declared it", %{
      workflow: workflow,
      person: person
    } do
      {finished, step_runs} = run(workflow, person, payload(person, %{"sequence" => "1"}))

      assert finished.status == "failed"

      failed = Enum.find(step_runs, &(&1.status == "failed"))
      assert failed.step_name == "bump_sequence"
      # The step refuses it in the same words the contract would have used.
      assert failed.errors["reason"] =~ "value: expected integer, got string"
    end
  end
end
