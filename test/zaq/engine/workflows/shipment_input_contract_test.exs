defmodule Zaq.Engine.Workflows.ShipmentInputContractTest do
  @moduledoc """
  Pushes the input contract past presence-and-type onto the third level: the rules an
  author declared.

  The graph and its three actions live in `Zaq.Engine.Workflows.Test.ShipmentActions`,
  so this file depends on nothing under `test/support/fixtures/workflows/` and on
  nothing in `lib/zaq/agent/tools/`.

  `ValidateShipment` declares one of each rule Zoi can express on a scalar, plus a
  rule *inside* a list, so a failure has somewhere deeper than the top level to be
  reported from. `DispatchShipmentNotice` declares the same graph's other half in
  NimbleOptions, which carries types and a choice set but no rules — so one fixture
  shows both dialects reaching the same verdict shape.

  Three payload paths cover the three ways a value reaches a field:

    * `profile`     — an edge mapping, so the value arrives whole
    * `priority`    — a lone `{{start.…}}` param, so it also arrives whole
    * `customer_name` — interpolated into a RunAgent prompt, so it stringifies and
      is honestly untyped

  Both ends are asserted: the contract before dispatch, and a real run.
  """
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Zaq.InputContractHelpers

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.ShipmentActions
  alias Zaq.Engine.Workflows.Test.ShipmentActions.ScoreShipmentRisk
  alias Zaq.Engine.Workflows.Test.ShipmentActions.ValidateShipment
  alias Zaq.Engine.Workflows.Test.UseCaseStubs

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    {:ok, workflow} = Workflows.import_workflow(ShipmentActions.graph())

    # `AgentStub` declares `input` optional where `RunAgent` requires it, which moves
    # `customer_name` between the two lists — so the contract is asserted against the
    # graph as authored and only the run uses the stubbed copy.
    {:ok, runnable} =
      Workflows.import_workflow(ShipmentActions.graph(draft_notice: UseCaseStubs.AgentStub))

    %{workflow: workflow, runnable: runnable}
  end

  # Every required path, each holding a value its schema accepts. A test that means
  # to break one rule overrides exactly that key, so the failure it asserts is the
  # only one in the verdict.
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

  defp run(workflow, payload) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => %{},
        "actor" => %{"person" => nil},
        "assigns" => %{"trigger_type" => "manual", "input" => payload, "machine" => true},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = Workflows.WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(finished.id)}
  end

  describe "the contract it demonstrates" do
    test "asks for eight paths and offers two more", %{workflow: workflow} do
      assert InputContract.required_inputs(workflow) == [
               "channel",
               "customer_name",
               "label",
               "notify_email",
               "profile",
               "quantity",
               "reference_code",
               "weight_kg"
             ]

      assert InputContract.optional_inputs(workflow) ==
               ["attempts", "priority", "reviewer_email", "threshold"]
    end

    test "every path carries its declared kind", %{workflow: workflow} do
      assert InputContract.input_types(workflow) == %{
               "channel" => "one of: email, sms, webhook",
               "customer_name" => "any",
               "label" => "string",
               "notify_email" => "string",
               "profile" => "map",
               "quantity" => "integer",
               "reference_code" => "string",
               "threshold" => "integer",
               "weight_kg" => "float",
               "priority" => "one of: standard, express, overnight",
               "attempts" => "integer",
               "reviewer_email" => "string"
             }
    end

    # `channel` is required by nothing the payload reaches directly — it is named by
    # the condition on the `start` edge and by the mapping into `notify`. Either alone
    # would put it in the contract; both together must not double-report it.
    test "a path named by both an edge condition and a mapping is reported once",
         %{workflow: workflow} do
      verdict = InputContract.check(workflow, payload() |> Map.delete("channel"))

      assert missing(verdict) == [["channel"]]
    end
  end

  describe "declared rules are enforced before the run" do
    test "a pattern", %{workflow: workflow} do
      verdict = InputContract.check(workflow, payload(%{"reference_code" => "abc-1234"}))

      assert %{code: :invalid_format, message: message} =
               error_at(verdict, ["reference_code"])

      assert message =~ "must match pattern"
    end

    test "a minimum and a maximum length", %{workflow: workflow} do
      assert %{code: :greater_than_or_equal_to, message: too_small} =
               workflow
               |> InputContract.check(payload(%{"label" => "no"}))
               |> error_at(["label"])

      assert too_small =~ "at least 8 character(s)"

      assert %{code: :less_than_or_equal_to, message: too_big} =
               workflow
               |> InputContract.check(payload(%{"label" => "waaaaaaaytoolong"}))
               |> error_at(["label"])

      assert too_big =~ "at most 12 character(s)"
    end

    # JSON has one number type, so a weight of 3.0 arrives as `3`. It is widened to a
    # float before judging — not by widening the *spec* to `float | integer`, which
    # would let `0` through the integer branch and lose `gt(0)` entirely.
    test "a whole number satisfies a float field without losing its bound", %{
      workflow: workflow
    } do
      assert InputContract.check(workflow, payload(%{"weight_kg" => 3})).valid?

      assert %{code: :greater_than} =
               workflow
               |> InputContract.check(payload(%{"weight_kg" => 0}))
               |> error_at(["weight_kg"])

      # And the reported kind stays the one the author declared.
      assert InputContract.input_types(workflow)["weight_kg"] == "float"
    end

    test "a numeric bound", %{workflow: workflow} do
      assert %{code: :less_than_or_equal_to} =
               workflow
               |> InputContract.check(payload(%{"quantity" => 900}))
               |> error_at(["quantity"])

      assert %{code: :greater_than} =
               workflow
               |> InputContract.check(payload(%{"weight_kg" => 0.0}))
               |> error_at(["weight_kg"])
    end

    test "a format", %{workflow: workflow} do
      assert %{code: :invalid_format, message: "invalid email format"} =
               workflow
               |> InputContract.check(payload(%{"notify_email" => "nope"}))
               |> error_at(["notify_email"])
    end

    # The NimbleOptions dialect carries no rules, but it does carry a choice set —
    # and it reaches the same `code` the Zoi enum does.
    test "a choice set declared in the NimbleOptions dialect", %{workflow: workflow} do
      assert %{code: :invalid_enum_value} =
               workflow
               |> InputContract.check(payload(%{"channel" => "carrier-pigeon"}))
               |> error_at(["channel"])
    end

    # Optional forgives absence, not the wrong value — asserted in both directions and
    # for both wiring mechanisms, because a contract handling only one would look
    # correct. `priority` and `threshold` are lone `{{start.…}}` params; `attempts`
    # is wired by an edge mapping.
    test "omitting every optional path is valid", %{workflow: workflow} do
      assert InputContract.check(workflow, payload()).valid?
    end

    test "supplying every optional path correctly is valid", %{workflow: workflow} do
      good =
        payload(%{
          "priority" => "express",
          "threshold" => 80,
          "attempts" => 3,
          "reviewer_email" => "risk@example.com"
        })

      assert InputContract.check(workflow, good).valid?
    end

    test "an optional wired as a lone param is judged when supplied", %{workflow: workflow} do
      assert refused(InputContract.check(workflow, payload(%{"priority" => "yesterday"}))) ==
               [["priority"]]

      assert [%{code: :less_than_or_equal_to}] =
               InputContract.check(workflow, payload(%{"threshold" => 500})).errors
    end

    test "an optional wired by an edge mapping is judged when supplied", %{workflow: workflow} do
      assert %{code: :invalid_type} =
               workflow
               |> InputContract.check(payload(%{"attempts" => "three"}))
               |> error_at(["attempts"])
    end

    # A third way a Zoi field can be optional, and the only one that is not a wrapper:
    # `Zoi.optional/1` clears `required` on the field itself. `priority` and `threshold`
    # are optional by carrying a default, `attempts` by a NimbleOptions `required: false`
    # — so this is the shape neither of those covers.
    test "an optional declared with Zoi.optional/1 is offered, not demanded", %{
      workflow: workflow
    } do
      refute "reviewer_email" in InputContract.required_inputs(workflow)
      assert "reviewer_email" in InputContract.optional_inputs(workflow)

      assert InputContract.check(workflow, payload()).valid?
    end

    test "and is still judged against its rule when supplied", %{workflow: workflow} do
      assert InputContract.check(workflow, payload(%{"reviewer_email" => "risk@example.com"})).valid?

      assert %{code: :invalid_format, message: "invalid email format"} =
               workflow
               |> InputContract.check(payload(%{"reviewer_email" => "not-an-address"}))
               |> error_at(["reviewer_email"])
    end

    # Optional-by-default and optional-by-Zoi.optional differ in what an omission
    # means: a default fills the value in, `Zoi.optional/1` leaves it absent. Both are
    # omittable, which is the only thing the contract claims.
    test "an omitted Zoi.optional field is absent, where a defaulted one is filled in",
         %{workflow: workflow} do
      assert InputContract.check(workflow, payload()).valid?

      {:ok, parsed} =
        Zoi.parse(ScoreShipmentRisk.schema(), %{
          shipment_id: "shp_1",
          profile: %{region: "emea", fragile: false}
        })

      assert parsed[:threshold] == 50
      refute Map.has_key?(parsed, :reviewer_email)
    end

    # Absence is the only thing optional forgives: an explicit nil is an omission, not
    # a value, and must not be reported as required either.
    test "an optional path supplied as nil is neither refused nor demanded", %{
      workflow: workflow
    } do
      verdict = InputContract.check(workflow, payload(%{"priority" => nil, "attempts" => nil}))

      assert verdict.valid?
    end

    # A rule declared on a list's *elements* reports at the element's index, which is
    # the case a dotted path string could not have spelled.
    test "a rule inside a list reports at its index", %{workflow: workflow} do
      # `tags` is not wired by this graph, so it is not a payload path — the rule is
      # asserted on the spec the contract would use if it were.
      refute "tags" in InputContract.required_inputs(workflow)
      refute "tags" in InputContract.optional_inputs(workflow)

      {"tags", tags, false} =
        Enum.find(Action.field_specs(ValidateShipment), &(elem(&1, 0) == "tags"))

      assert [%{code: :greater_than_or_equal_to, path: [0]}] = Action.field_errors(tags, ["a"])
    end
  end

  describe "boundaries are inclusive on both sides" do
    # Off-by-one in either direction is the classic way a declared bound is wrong
    # while still looking enforced, so both edges and both misses are asserted.
    for {field, value, verdict} <- [
          {"quantity", 1, :valid},
          {"quantity", 500, :valid},
          {"quantity", 0, :invalid},
          {"quantity", 501, :invalid},
          {"label", "12345678", :valid},
          {"label", "123456789012", :valid},
          {"label", "1234567", :invalid},
          {"label", "1234567890123", :invalid},
          {"label", "", :invalid},
          {"weight_kg", 0.0, :invalid},
          {"weight_kg", 0.001, :valid}
        ] do
      test "#{field} = #{inspect(value)} is #{verdict}", %{workflow: workflow} do
        result =
          InputContract.check(
            workflow,
            payload(%{unquote(field) => unquote(Macro.escape(value))})
          ).valid?

        case unquote(verdict) do
          :valid -> assert result
          :invalid -> refute result
        end
      end
    end
  end

  describe "an anchored pattern is anchored" do
    # PCRE's `$` also matches immediately before a trailing newline, so `^…$` accepts
    # a value with one appended. The schema uses `\\A…\\z` for that reason, and this
    # is the case that proves it.
    test "a trailing newline does not satisfy the reference pattern", %{workflow: workflow} do
      verdict = InputContract.check(workflow, payload(%{"reference_code" => "ABC-1234\n"}))

      assert %{code: :invalid_format} = error_at(verdict, ["reference_code"])
    end

    test "a newline-smuggled suffix does not either", %{workflow: workflow} do
      verdict = InputContract.check(workflow, payload(%{"reference_code" => "ABC-1234\nEVIL"}))

      assert %{code: :invalid_format} = error_at(verdict, ["reference_code"])
    end
  end

  # The claim the whole design rests on: the contract's verdict is the run's verdict.
  # Asserting it for one rule proves nothing about the others, so every rule class is
  # driven through a real run and the refusing step is named.
  describe "every rule class refuses in the run exactly as it did in the contract" do
    for {label, extra, step} <- [
          {"a pattern", %{"reference_code" => "abc-1234"}, "validate"},
          {"a minimum length", %{"label" => "no"}, "validate"},
          {"a maximum length", %{"label" => "waaaaaaaytoolong"}, "validate"},
          {"an upper bound", %{"quantity" => 900}, "validate"},
          {"a lower bound", %{"weight_kg" => 0.0}, "validate"},
          {"an email format", %{"notify_email" => "nope"}, "validate"},
          {"a Zoi enum", %{"priority" => "yesterday"}, "validate"},
          {"a NimbleOptions choice set", %{"channel" => "carrier-pigeon"}, "notify"}
        ] do
      test "#{label} refuses at #{step}", %{runnable: runnable} do
        bad = payload(unquote(Macro.escape(extra)))

        refute InputContract.check(runnable, bad).valid?

        {finished, step_runs} = run(runnable, bad)

        refute finished.status == "completed"

        refusing = Enum.find(step_runs, &(&1.step_name == unquote(step)))

        assert refusing.status == "failed",
               "expected #{unquote(step)} to fail, got #{inspect(refusing && refusing.status)}"
      end
    end
  end

  describe "properties" do
    property "quantity is valid exactly on 1..500", %{workflow: workflow} do
      check all(quantity <- integer(-200..900)) do
        valid? = InputContract.check(workflow, payload(%{"quantity" => quantity})).valid?

        assert valid? == (quantity >= 1 and quantity <= 500)
      end
    end

    property "label is valid exactly on lengths 8..12", %{workflow: workflow} do
      check all(label <- string(?a..?z, min_length: 0, max_length: 20)) do
        valid? = InputContract.check(workflow, payload(%{"label" => label})).valid?

        assert valid? == String.length(label) in 8..12
      end
    end

    # Whatever the payload, the verdict never contradicts itself: `valid?` is exactly
    # `errors == []`, and every error carries a path the caller can act on.
    property "the verdict is internally consistent for any payload", %{workflow: workflow} do
      check all(extra <- map_of(string(:alphanumeric, min_length: 1), term()), max_runs: 50) do
        verdict = InputContract.check(workflow, payload(extra))

        assert verdict.valid? == (verdict.errors == [])
        assert Enum.all?(verdict.errors, &(is_list(&1.path) and &1.path != []))
        assert Enum.all?(verdict.errors, &is_atom(&1.code))
        assert Enum.all?(verdict.errors, &is_binary(&1.message))
      end
    end
  end

  describe "the run agrees with the contract" do
    test "a payload the contract accepts runs to completion", %{runnable: runnable} do
      # Carries every optional too, so the mapping-wired one reaches the step. The
      # emea/fragile profile scores 55, so a threshold under it flags the shipment and
      # the risk gate opens.
      full = payload(%{"priority" => "express", "threshold" => 40, "attempts" => 3})

      assert InputContract.check(runnable, full).valid?

      {finished, step_runs} = run(runnable, full)

      assert finished.status == "completed"
      assert Enum.any?(step_runs, &(&1.step_name == "notify"))
    end

    # An optional path is not decoration: supplying it changes what the run does. The
    # same payload with a threshold above the score leaves the gate shut, which is how
    # we know the value reached the step rather than being dropped somewhere.
    test "an optional value the contract accepted reaches the step", %{runnable: runnable} do
      below = payload(%{"threshold" => 40})
      above = payload(%{"threshold" => 80})

      assert InputContract.check(runnable, below).valid?
      assert InputContract.check(runnable, above).valid?

      {opened, _} = run(runnable, below)
      {shut, _} = run(runnable, above)

      assert opened.status == "completed"
      assert shut.status == "incomplete"
    end

    # The contract's verdict is the run's verdict: the same spec judges the same value
    # in both places, so a rule the pre-flight refuses is a rule the step refuses.
    test "a payload the contract refuses is refused by the step too", %{runnable: runnable} do
      bad = payload(%{"label" => "no"})

      refute InputContract.check(runnable, bad).valid?

      {finished, step_runs} = run(runnable, bad)

      refute finished.status == "completed"

      validate = Enum.find(step_runs, &(&1.step_name == "validate"))
      assert validate.status == "failed"
      assert inspect(validate.errors) =~ "at least 8 character(s)"
    end
  end
end
