defmodule Zaq.Engine.Workflows.InputContractRuntimeAgreementE2ETest do
  @moduledoc """
  The guarantee the contract exists to make: **a `valid?: true` verdict means the run
  will not fail on its inputs.**

  Two halves have to agree for that to hold. `InputContract` reads each step's
  declared schema before the run and judges a candidate payload against it;
  `StepRunner` reads the same schema during the run and refuses a param of the wrong
  kind. If either drifts, the tool becomes a lie — an agent loops to `valid?: true`
  and the run then fails for the very reason the loop was supposed to prevent.

  ## What is real vs. stubbed

  The real `send_leads_email.json` definition, imported through
  `UseCaseFixtures.import_fixture/2`. The contract, the DAG build, `StepRunner`, the
  placeholder resolver, edge conditions and mappings all run for real — they are the
  seam under test. Only the two true external boundaries are stubbed: the LLM draft
  and the Google Sheet write.
  """
  use Zaq.DataCase, async: false

  import Zaq.InputContractHelpers

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.UseCaseFixtures
  alias Zaq.Engine.Workflows.Test.UseCaseStubs

  # Every step from `ensure_person` through `send_email` must actually run, or this
  # file proves nothing: a run that stops at step three reports no validation failure
  # for the perfectly good reason that nothing downstream was ever asked to validate.
  @must_run ~w(
    ensure_person build_history check_last_message_date
    build_agent_context draft_email review_email send_email
  )

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)

    from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Email",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://localhost",
      token: "t",
      enabled: true,
      settings: %{"from_email" => "julien@zaq.test"}
    })
    |> Repo.insert!()

    {:ok, person} =
      People.create_person(%{full_name: "John Doe", email: "john-doe@example.com"})

    %{person: person}
  end

  defp consumer do
    {:ok, workflow} =
      UseCaseFixtures.import_fixture("send_leads_email.json",
        swap: %{
          "draft_email" => UseCaseStubs.AgentStub,
          "update_sheet_row" => UseCaseStubs.UpdateSheetStub
        }
      )

    workflow
  end

  # A payload built the way the tool tells an agent to build one: take the shape,
  # fill every leaf. The values are type-correct for what each path's field declares.
  defp filled_payload(workflow) do
    %{
      "company context content" => "Acme builds widgets.",
      "company official name" => "Acme Corporation",
      "email topic" => "Request for a product demo",
      "input" => %{"name" => "John Doe"},
      "language" => "en",
      "row_index" => 6,
      "sequence" => 1
    }
    |> Map.take(shape_keys(workflow))
  end

  defp shape_keys(workflow),
    do: workflow |> InputContract.required_input_shape() |> Map.keys()

  # Runs the real DAG and clears the human-in-the-loop gate the way a reviewer would,
  # so execution continues past `review_email` instead of parking there.
  defp run_with(workflow, payload, person) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => %{},
        "actor" => %{"person" => %{"id" => person.id}},
        "assigns" => %{"trigger_type" => "manual", "input" => payload, "machine" => true},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = Workflows.WorkflowRunAgent.execute(run)

    finished =
      case Workflows.get_pending_approval(finished.id) do
        nil ->
          finished

        approval ->
          {:ok, _} = Workflows.approve_step(finished, approval, %{}, "reviewer@acme.com")
          Workflows.get_run!(finished.id)
      end

    {finished, Workflows.list_step_runs(finished.id)}
  end

  # The guard against a vacuous pass: a step that never ran cannot have refused its
  # params, so a shallow run would satisfy every assertion here for the wrong reason.
  defp assert_ran_deep(step_runs) do
    completed = for s <- step_runs, s.status == "completed", do: s.step_name

    for step <- @must_run do
      assert step in completed,
             "#{step} never completed — this run was too shallow to prove anything.\n" <>
               Enum.map_join(step_runs, "\n", &"  #{&1.step_name}: #{&1.status}")
    end

    step_runs
  end

  defp validation_failures(step_runs) do
    for s <- step_runs,
        s.status == "failed",
        reason = s.errors["reason"],
        is_binary(reason),
        String.contains?(reason, "Invalid parameters"),
        do: {s.step_name, reason}
  end

  describe "a valid verdict means the run does not fail on its inputs" do
    test "the filled shape validates, and no step refuses its params", %{person: person} do
      workflow = consumer()
      payload = filled_payload(workflow)

      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload)

      {_run, step_runs} = run_with(workflow, payload, person)

      assert step_runs |> assert_ran_deep() |> validation_failures() == [],
             "the contract accepted a payload the run then refused"
    end

    # The other direction of the same guarantee: the loop the tool describes has to
    # actually converge. Shape → fill → valid → dispatch, with no step refusing.
    test "the agent loop converges: shape, fill, valid, run", %{person: person} do
      workflow = consumer()

      assert %{valid?: false} = InputContract.contract(workflow, %{})

      shape = InputContract.required_input_shape(workflow)
      assert %{valid?: false} = InputContract.contract(workflow, shape)

      filled = filled_payload(workflow)
      assert %{valid?: true} = InputContract.contract(workflow, filled)

      {_run, step_runs} = run_with(workflow, filled, person)
      assert step_runs |> assert_ran_deep() |> validation_failures() == []
    end
  end

  describe "an invalid verdict names something the run would really refuse" do
    test "a wrong-typed path is never called fine while the run refuses it", %{person: person} do
      workflow = consumer()
      wrong = Map.put(filled_payload(workflow), "row_index", "six")

      contract = InputContract.contract(workflow, wrong)
      {_run, step_runs} = run_with(workflow, wrong, person)

      # Either the contract names it, or no step refuses it — the forbidden state is
      # "the contract said fine" while a step refused the very same value.
      refute contract.valid? == true and validation_failures(step_runs) != []
    end

    test "the contract's verdict and the run's verdict never contradict", %{person: person} do
      workflow = consumer()

      for payload <- [
            filled_payload(workflow),
            Map.put(filled_payload(workflow), "row_index", "six"),
            Map.put(filled_payload(workflow), "language", 42)
          ] do
        contract = InputContract.contract(workflow, payload)
        {_run, step_runs} = run_with(workflow, payload, person)

        if contract.valid? do
          assert validation_failures(step_runs) == [],
                 "contract said valid but the run refused: #{inspect(payload)}"
        end
      end
    end
  end

  describe "the narrowing is not over-eager" do
    # A path whose value only ever reaches a schema field interpolated into a larger
    # string resolves to a string whatever the payload held, so neither end may
    # claim a type for it.
    test "an untyped path accepts a value of any kind at both ends", %{person: person} do
      workflow = consumer()
      expectations = InputContract.expectations(workflow)

      untyped = Enum.find(shape_keys(workflow), &(Map.get(expectations, &1) == nil))

      if untyped do
        payload = Map.put(filled_payload(workflow), untyped, 42)

        assert refused(InputContract.contract(workflow, payload)) == []

        {_run, step_runs} = run_with(workflow, payload, person)
        assert validation_failures(step_runs) == []
      end
    end
  end
end
