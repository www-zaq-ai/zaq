defmodule Zaq.Engine.Workflows.InputContractRefinementTest do
  @moduledoc """
  A declared type is not the whole contract. `CredentialAction` declares Zoi
  *refinements* on top of its field types — `email` must match `~r/@/`, `password`
  must be 8..12 characters, and the optional `nickname` must be at least 3 — so a
  value of exactly the right kind can still be refused.

  Two things have to hold for the contract to be worth anything here:

    * a well-typed value that breaks a rule is **invalid**, not supplied. The
      pre-flight check runs `Zoi.parse/2`, the same judge `StepRunner` runs, so a
      refinement is not something it can be blind to.
    * the report names **the rule**. `expected` and `got` both read `"string"` for a
      refinement failure — true and useless — so `message` carries Zoi's own wording
      and is the part a caller acts on.

  Optional is orthogonal to all of it: `nickname` may be omitted, and supplied it is
  held to its rule like any other field.

  The run half executes the real `create_workflow` → `create_run` → `DagBuilder` →
  `WorkflowRunAgent` → `StepRunner` path, so every verdict is checked against what
  the step actually does with the same payload.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.CredentialAction
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @module to_string(CredentialAction)

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, & &1)
    :ok
  end

  # One entry node, every field wired straight out of the trigger payload.
  defp graph do
    %{
      "nodes" => [%{"name" => "signup", "module" => @module, "params" => %{}}],
      "edges" => [
        %{
          "from" => "start",
          "to" => "signup",
          "mapping" => %{
            "email" => "start.email",
            "password" => "start.password",
            "nickname" => "start.nickname"
          },
          "condition" => nil
        }
      ]
    }
  end

  defp workflow do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Credentials #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [%{name: "signup", type: "action", module: @module, index: 0, params: %{}}],
        edges: [
          %{
            from: "start",
            to: "signup",
            mapping: %{
              "email" => "start.email",
              "password" => "start.password",
              "nickname" => "start.nickname"
            }
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

  defp step_failure(step_runs) do
    Enum.find_value(step_runs, fn s ->
      reason = s.errors["reason"]

      if s.status == "failed" and is_binary(reason) and
           String.contains?(reason, "Invalid parameters"),
         do: reason
    end)
  end

  defp valid_payload(overrides \\ %{}),
    do: Map.merge(%{"email" => "a@b.c", "password" => "hunter22"}, overrides)

  defp invalid_for(payload), do: InputContract.contract(graph(), payload).invalid_inputs

  describe "the contract" do
    test "a refined field is required or optional the same way any field is" do
      g = graph()

      assert InputContract.required_inputs(g) == ["email", "password"]
      assert InputContract.optional_inputs(g) == ["nickname"]
    end

    test "a payload satisfying every rule is valid" do
      assert %{valid: true, missing_inputs: [], invalid_inputs: []} =
               InputContract.contract(graph(), valid_payload())
    end
  end

  describe "a rule on a required field" do
    test "an email without @ is invalid, and the message names the pattern" do
      assert [violation] = invalid_for(valid_payload(%{"email" => "nope"}))

      assert violation.path == "email"
      assert violation.message == "invalid format: must match pattern @"
    end

    # The sharp edge, stated rather than hidden: the value *is* a string, so the kind
    # pair says so twice. It is `message` that carries the reason.
    test "the kind pair cannot express a refinement — the message is what carries it" do
      assert [violation] = invalid_for(valid_payload(%{"email" => "nope"}))

      assert violation.expected == "string"
      assert violation.got == "string"
      refute violation.message =~ "expected string, got string"
    end

    test "a password under the minimum is invalid" do
      assert [violation] = invalid_for(valid_payload(%{"password" => "short"}))

      assert violation.path == "password"
      assert violation.message == "too small: must have at least 8 character(s)"
    end

    test "a password over the maximum is invalid" do
      assert [violation] = invalid_for(valid_payload(%{"password" => "way-too-long-password"}))

      assert violation.message == "too big: must have at most 12 character(s)"
    end

    # The rules are inclusive at both ends — asserted so a later `gt`/`lt` slip shows up.
    test "the boundary lengths are accepted" do
      for password <- [String.duplicate("a", 8), String.duplicate("a", 12)] do
        assert %{valid: true, invalid_inputs: []} =
                 InputContract.contract(graph(), valid_payload(%{"password" => password})),
               "#{String.length(password)} characters should be accepted"
      end
    end

    test "one path per broken rule, so a caller sees every one at once" do
      violations = invalid_for(%{"email" => "nope", "password" => "short"})

      assert Enum.map(violations, & &1.path) == ["email", "password"]
    end

    # A wrong *kind* still reads as a kind mismatch — that branch is not lost.
    test "a wrong kind still names what arrived" do
      assert [violation] = invalid_for(valid_payload(%{"email" => 42}))

      assert violation.message == "expected string, got integer"
      assert violation.got == "integer"
    end
  end

  describe "a rule on an optional field" do
    test "omitting it is valid — the rule has nothing to judge" do
      assert %{valid: true, missing_inputs: [], invalid_inputs: []} =
               InputContract.contract(graph(), valid_payload())
    end

    test "supplying it too short is invalid, and it is not reported missing" do
      assert %{valid: false, missing_inputs: [], invalid_inputs: [violation]} =
               InputContract.contract(graph(), valid_payload(%{"nickname" => "ab"}))

      assert violation.path == "nickname"
      assert violation.message == "too small: must have at least 3 character(s)"
    end

    test "supplying it correctly is valid" do
      assert %{valid: true, invalid_inputs: []} =
               InputContract.contract(graph(), valid_payload(%{"nickname" => "abc"}))
    end
  end

  describe "against the real run" do
    test "a payload the contract clears runs to completion" do
      w = workflow()
      payload = valid_payload(%{"nickname" => "abc"})

      assert %{valid: true} = InputContract.contract(w, payload)

      {_run, step_runs} = run_with(w, payload)

      assert step_failure(step_runs) == nil
      assert Enum.any?(step_runs, &(&1.step_name == "signup" and &1.status == "completed"))
    end

    # `Action.explain/2` is the one judge both sides read, so the run's refusal is the
    # pre-flight message verbatim.
    test "the run refuses a broken rule in the same words the contract used" do
      w = workflow()

      for {field, value} <- [
            {"email", "nope"},
            {"password", "short"},
            {"password", "way-too-long-password"},
            {"nickname", "ab"}
          ] do
        payload = valid_payload(%{field => value})

        assert %{invalid_inputs: [%{path: ^field, message: message}]} =
                 InputContract.contract(w, payload)

        {_run, step_runs} = run_with(w, payload)

        assert step_failure(step_runs) == "Invalid parameters: #{field}: #{message}",
               "run and contract disagreed on #{field}=#{inspect(value)}"
      end
    end

    # The invariant, not an example: a cleared payload is one the run accepts.
    test "the contract never clears a value the run refuses" do
      w = workflow()

      for email <- ["a@b.c", "nope", "@", 42],
          password <- ["hunter22", "short", "way-too-long-password"],
          nickname <- [nil, "abc", "ab"] do
        payload =
          %{"email" => email, "password" => password}
          |> then(&if(nickname, do: Map.put(&1, "nickname", nickname), else: &1))

        contract = InputContract.contract(w, payload)
        {_run, step_runs} = run_with(w, payload)

        if contract.valid do
          assert step_failure(step_runs) == nil,
                 "contract cleared #{inspect(payload)} but the run refused it"
        end
      end
    end
  end
end
