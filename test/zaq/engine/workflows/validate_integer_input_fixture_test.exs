defmodule Zaq.Engine.Workflows.ValidateIntegerInputFixtureTest do
  @moduledoc """
  Pins `validate_integer_input.json` — the fixture that demonstrates the typed input
  contract on the smallest graph that can show all three cases at once:

    * `person_id` — required and `Zoi.integer()` (`UpdatePerson`, Zoi dialect)
    * `sequence`  — required and `type: :integer` (`Increment`, NimbleOptions dialect)
    * `name`      — reached only through an interpolated placeholder, so no schema
      can type it and both ends stay presence-only

  A fixture with no consumer drifts, and this one is a worked example people will
  copy. Both ends are asserted: the contract before dispatch, and a real run.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.UseCaseFixtures

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    {:ok, workflow} = UseCaseFixtures.import_fixture("validate_integer_input.json")
    {:ok, person} = People.create_person(%{full_name: "Ada", email: "ada@example.com"})

    %{workflow: workflow, person: person}
  end

  defp payload(person, extra),
    do: Map.merge(%{"person_id" => person.id, "sequence" => 1, "name" => "Ada"}, extra)

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
    test "asks for three paths and types two of them", %{workflow: workflow} do
      assert InputContract.required_inputs(workflow) == ["name", "person_id", "sequence"]

      assert workflow |> InputContract.expectations() |> Map.keys() |> Enum.sort() ==
               ["person_id", "sequence"]

      # A sound graph: nothing it needs is beyond any payload's reach.
      assert InputContract.unsatisfiable_inputs(workflow) == []
    end

    test "a correctly-typed payload is valid", %{workflow: workflow, person: person} do
      assert %{valid: true, missing_inputs: [], invalid_inputs: []} =
               InputContract.contract(workflow, payload(person, %{}))
    end

    test "a Zoi-declared integer refuses a string", %{workflow: workflow, person: person} do
      assert %{valid: false, invalid_inputs: [violation], missing_inputs: []} =
               InputContract.contract(workflow, payload(person, %{"person_id" => "42"}))

      assert violation == %{path: "person_id", expected: "integer", got: "string"}
    end

    test "a NimbleOptions-declared integer refuses a string too", %{
      workflow: workflow,
      person: person
    } do
      assert %{valid: false, invalid_inputs: [violation]} =
               InputContract.contract(workflow, payload(person, %{"sequence" => "1"}))

      assert violation == %{path: "sequence", expected: "integer", got: "string"}
    end

    # `name` only ever reaches a field interpolated into a larger string, which
    # resolves to a string whatever the payload held — so no type is claimed for it.
    test "the untyped path takes a value of any kind", %{workflow: workflow, person: person} do
      assert %{valid: true, invalid_inputs: []} =
               InputContract.contract(workflow, payload(person, %{"name" => 99}))
    end

    test "null is missing, not invalid", %{workflow: workflow, person: person} do
      assert %{valid: false, missing_inputs: ["person_id"], invalid_inputs: []} =
               InputContract.contract(workflow, payload(person, %{"person_id" => nil}))
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
