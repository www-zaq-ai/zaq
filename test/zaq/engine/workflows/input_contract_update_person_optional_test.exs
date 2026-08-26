defmodule Zaq.Engine.Workflows.InputContractUpdatePersonOptionalTest do
  @moduledoc """
  A `start.*` path wired into an **optional** field of a real action, on the action
  the question was asked about: `Zaq.Agent.Tools.People.UpdatePerson`.

  Its schema is `person_id` (required integer) plus `attrs` — an optional
  `Zoi.map` whose own fields include `email` (string) and `status` (an enum of
  `"active"` / `"inactive"`). So the workflow below reads two payload paths and owes
  only one: `person_id` is required, `attrs` is optional.

  `email` and `status` are not payload paths of their own. The contract types a path
  at the granularity the graph wires it, and the graph wires `attrs` whole — so the
  spec that judges the value is the whole `attrs` map spec, nested fields included.

  Nothing is stubbed but `NodeRouter`: the real `create_workflow` → `create_run` →
  `DagBuilder` → `WorkflowRunAgent` → `StepRunner` path executes, so every verdict
  here is checked against what the run actually does with the same payload.
  """
  use Zaq.DataCase, async: true

  import Zaq.InputContractHelpers

  alias Zaq.Accounts.People
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @module "Zaq.Agent.Tools.People.UpdatePerson"

  # `UpdatePerson` dispatches through the real `NodeRouter` — `StepRunner` hands it an
  # empty context, so there is no mock to inject. A real row is what makes the run
  # half of this file honest: the step reaches the Engine and updates it.
  setup do
    stub(Zaq.NodeRouterMock, :dispatch, & &1)

    {:ok, person} =
      People.create_person(%{
        "full_name" => "Person #{System.unique_integer([:positive])}",
        "email" => "p#{System.unique_integer([:positive])}@example.com"
      })

    %{person_id: person.id}
  end

  # One entry node fed straight from the trigger payload, both fields wired whole.
  defp graph do
    %{
      "nodes" => [%{"name" => "update", "module" => @module, "params" => %{}}],
      "edges" => [
        %{
          "from" => "start",
          "to" => "update",
          "mapping" => %{"person_id" => "start.person_id", "attrs" => "start.attrs"},
          "condition" => nil
        }
      ]
    }
  end

  defp workflow do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Update person #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [%{name: "update", type: "action", module: @module, index: 0, params: %{}}],
        edges: [
          %{
            from: "start",
            to: "update",
            mapping: %{"person_id" => "start.person_id", "attrs" => "start.attrs"}
          }
        ]
      })

    workflow
  end

  defp run_with(workflow, payload) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => %{},
        "assigns" => %{"trigger_type" => "manual", "input" => payload, "machine" => true},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(finished.id)}
  end

  # The edge out of `start` is an injected `EdgeStep` with a run row of its own, so
  # the action's row is picked by name rather than by being the only one.
  defp update_step(step_runs), do: Enum.find(step_runs, &(&1.step_name == "update"))

  defp validation_failures(step_runs) do
    for s <- step_runs,
        s.status == "failed",
        reason = s.errors["reason"],
        is_binary(reason),
        String.contains?(reason, "Invalid parameters"),
        do: {s.step_name, reason}
  end

  describe "the split" do
    test "the required field is owed, the optional one is only named" do
      g = graph()

      assert InputContract.required_inputs(g) == ["person_id"]
      assert InputContract.optional_inputs(g) == ["attrs"]

      # The skeleton asks for what the run cannot do without, and no more.
      assert InputContract.required_input_shape(g) == %{"person_id" => nil}
    end

    test "omitting the optional path is valid" do
      assert %{valid?: true, errors: []} =
               InputContract.contract(graph(), %{"person_id" => 1})
    end

    test "omitting the required path is not" do
      assert %{valid?: false, errors: [%{code: :required, path: ["person_id"]}]} =
               InputContract.contract(graph(), %{"attrs" => %{email: "a@b.c"}})
    end

    test "the required path carries its declared type" do
      assert %{valid?: false, errors: invalid} =
               InputContract.contract(graph(), %{"person_id" => "1"})

      assert [
               %{
                 path: ["person_id"],
                 code: :invalid_type,
                 message: "expected integer, got string"
               }
             ] =
               invalid
    end
  end

  # The point of the optional list: named, not demanded — and still type-checked.
  describe "the optional path is type-checked when supplied" do
    test "a scalar where the field declares a map is invalid" do
      assert %{valid?: false, errors: invalid} =
               InputContract.contract(graph(), %{"person_id" => 1, "attrs" => "not a map"})

      assert [%{path: ["attrs"], code: :invalid_type, message: "expected map, got string"}] =
               invalid
    end

    # The two sides of the contract read the same `Zoi.parse/2` verdict through
    # `Action.explain/2`, so the run's refusal repeats the pre-flight message.
    test "the run refuses it in the same words", %{person_id: person_id} do
      w = workflow()
      payload = %{"person_id" => person_id, "attrs" => %{status: "pending"}}

      assert %{errors: [%{message: message}]} = InputContract.contract(w, payload)

      {_run, step_runs} = run_with(w, payload)

      assert [{"update", reason}] = validation_failures(step_runs)
      # Same words: the run adds only where it found the problem, which the contract
      # carries as `path` instead of folding into the sentence.
      assert reason =~ message
      assert reason =~ "Invalid parameters: attrs: "
    end

    test "a well-formed attrs map is valid" do
      payload = %{"person_id" => 1, "attrs" => %{email: "a@b.c", status: "active"}}

      assert %{valid?: true, errors: []} =
               InputContract.contract(graph(), payload)
    end

    # `email` and `status` live inside the `attrs` spec, so the whole map is judged
    # against it. The failure is *inside* the wired value, so `expected`/`got` are
    # both the container's kind and `message` carries the part an agent can act on —
    # which key, and what it wanted.
    test "an integer email fails, and the message names the key" do
      payload = %{"person_id" => 1, "attrs" => %{email: 42}}

      assert %{valid?: false, errors: invalid} =
               InputContract.contract(graph(), payload)

      # Zoi located it inside the value, so the path points at the offending key
      # rather than at the container the old kind pair could only name.
      assert [%{path: ["attrs", "email"], message: message}] = invalid
      assert message == "invalid type: expected string"
    end

    test "a status outside the enum fails, and the message names the choices" do
      payload = %{"person_id" => 1, "attrs" => %{status: "pending"}}

      assert %{valid?: false, errors: [%{path: ["attrs" | _], message: message}]} =
               InputContract.contract(graph(), payload)

      assert message == "invalid enum value: expected one of active, inactive"
    end

    test "an integer status fails" do
      payload = %{"person_id" => 1, "attrs" => %{status: 1}}
      verdict = InputContract.contract(graph(), payload)

      refute verdict.valid?

      # The location is a field now, not a suffix on the sentence.
      assert %{code: :invalid_enum_value} = error_at(verdict, ["attrs", "status"])
    end

    # Every located failure is reported, so a caller fixing them does not round-trip
    # once per field.
    # One error per broken key, each at its own path — where a single joined sentence
    # used to carry both and a reader had to parse the locations out of it.
    test "two bad keys are each their own error" do
      payload = %{"person_id" => 1, "attrs" => %{email: 42, status: "pending"}}
      verdict = InputContract.contract(graph(), payload)

      refute verdict.valid?
      assert error_at(verdict, ["attrs", "email"])
      assert error_at(verdict, ["attrs", "status"])
      assert Enum.all?(verdict.errors, &(not (&1.message =~ "\n")))
    end

    # A failure *at* the value is a kind mismatch, and Zoi never says what arrived —
    # so that half keeps the `schema_kind`/`value_kind` phrasing.
    test "a failure at the value itself reads as a kind mismatch" do
      assert %{errors: [%{path: ["attrs" | _], message: message}]} =
               InputContract.contract(graph(), %{"person_id" => 1, "attrs" => "not a map"})

      assert message == "expected map, got string"
    end
  end

  # The agreement the contract exists to make: what it clears, the run accepts.
  describe "against the real run" do
    test "a cleared payload runs to completion", %{person_id: person_id} do
      w = workflow()

      payload = %{
        "person_id" => person_id,
        "attrs" => %{"email" => "moved@example.com", "status" => "active"}
      }

      assert %{valid?: true} = InputContract.contract(w, payload)

      {_run, step_runs} = run_with(w, payload)

      assert validation_failures(step_runs) == []
      assert %{status: "completed"} = update_step(step_runs)
    end

    test "omitting the optional path runs to completion", %{person_id: person_id} do
      w = workflow()
      payload = %{"person_id" => person_id}

      assert %{valid?: true} = InputContract.contract(w, payload)

      {_run, step_runs} = run_with(w, payload)

      assert validation_failures(step_runs) == []
      assert %{status: "completed"} = update_step(step_runs)
    end

    # Stated as the invariant rather than as one example: the contract may never
    # clear a payload the run then refuses.
    test "the contract never clears a value the run refuses", %{person_id: person_id} do
      w = workflow()

      attrs_values = [
        %{"email" => "a@example.com", "status" => "active"},
        %{"email" => 42},
        %{"status" => "pending"},
        %{"status" => 1},
        %{email: 42},
        %{status: "pending"},
        "not a map",
        42
      ]

      for attrs <- attrs_values do
        payload = %{"person_id" => person_id, "attrs" => attrs}
        contract = InputContract.contract(w, payload)
        {_run, step_runs} = run_with(w, payload)

        if contract.valid? do
          assert validation_failures(step_runs) == [],
                 "contract cleared attrs=#{inspect(attrs)} but the run refused it"
        end
      end
    end
  end
end
