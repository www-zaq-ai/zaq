defmodule Zaq.Engine.Workflows.LeadPipelineE2ETest do
  @moduledoc """
  End-to-end coverage for the **real** lead pipeline, built by importing the
  production workflow JSON exports through `Workflows.import_workflow/1` and running
  them through the real engine. Only the true external boundaries (Google Sheet
  read/write, LLM draft, SMTP send) are swapped for stubs; every other node —
  `Batch` iteration, the `Condition` gates, `ExtractRows`, `EnsurePerson`,
  `Accounts.History`, the `Concat`s, the real `HumanInTheLoop` review, `Increment` —
  executes for real.

  Two halves of the pipeline are covered:

    * **Producer** (`identify_leads_from_google_sheet.json`) — the sheet scan fans
      each row through the real `Batch`, gated by `check_active` and
      `check_email_state`, and dispatches a machine-marked `lead_identified` event
      only for rows that pass both gates.

    * **Consumer** (`send_leads_email.json`) — triggered by the real `craft_email`
      event. Its `build_history` (`Accounts.History`) only resolves the mapped
      `person_id` when the run carries `skip_permissions: true`, which is granted
      only when the triggering event is `machine: true`. The authorization block
      pins both the positive and negative cases.

  Runs `async: false` because the producer fans out through `TriggerNode`/`Batch`
  and the consumer is triggered through `TriggerNode.fire/2`, both needing the
  shared Ecto sandbox with Mox `$callers` propagation.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Test.{UseCaseFixtures, UseCaseStubs}

  @lead_event_key "engine:lead_identified"
  @craft_email_key "engine:craft_email"

  @lead %{
    "email" => "john@acme.com",
    "name" => "John Doe",
    "email topic" => "Acme × ZAQ",
    "company official name" => "Acme Corp",
    "company context content" => "Acme builds industrial IoT sensors.",
    "language" => "english",
    "active" => true,
    "sequence" => 1,
    "row_index" => 2
  }

  # Captures the event the real DispatchEvent builds so the consumer can be
  # triggered directly for the focused authorization tests.
  defmodule CaptureRouter do
    @moduledoc false
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:captured, event})
      event
    end
  end

  # ── Setup ───────────────────────────────────────────────────────────────────

  setup do
    # The producer's real DispatchEvent (via the bridge) dispatches lead_identified
    # through this mock; record every dispatched event to a collector reachable from
    # the Batch/StepRunner process, then route it into TriggerNode as the live
    # EventRegistry would (a no-op when no workflow is registered on that key).
    Application.put_env(:zaq, :e2e_pipeline_collector, self())
    on_exit(fn -> Application.delete_env(:zaq, :e2e_pipeline_collector) end)

    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      case trigger_key(event) do
        nil ->
          :ok

        key ->
          send(collector(), {:dispatched, key, event})
          TriggerNode.fire(key, event)
      end

      event
    end)

    :ok
  end

  def collector, do: Application.get_env(:zaq, :e2e_pipeline_collector)

  # Mirrors EventRegistry: destination-prefix the base name unless already keyed.
  defp trigger_key(%{name: name, next_hop: %{destination: dest}})
       when is_binary(name) and is_atom(dest) do
    if String.contains?(name, ":"), do: name, else: "#{dest}:#{name}"
  end

  defp trigger_key(%{name: name}) when is_atom(name) and not is_nil(name) do
    n = Atom.to_string(name)
    if String.contains?(n, ":"), do: n, else: "engine:#{n}"
  end

  defp trigger_key(_), do: nil

  # ── Fixtures (real workflows, boundaries swapped) ────────────────────────────

  # Producer: get_sheet stubbed to fixture rows, dispatch_lead bridged onto the Mox
  # router, sleep_between shortened to 0. extract_rows, the Batch, and both Condition
  # gates stay real.
  defp create_producer do
    {:ok, workflow} =
      UseCaseFixtures.import_fixture("identify_leads_from_google_sheet.json",
        swap: %{
          "get_sheet" => UseCaseStubs.GetSheetStub,
          "dispatch_lead" => UseCaseStubs.BridgeDispatchEvent
        },
        patch: %{"sleep_between" => &UseCaseStubs.zero_sleep/1}
      )

    workflow
  end

  # Consumer: real ensure_person + Accounts.History + Condition + Concat + HITL +
  # Increment; only the LLM draft, send, history-persist, and sheet write stubbed.
  defp create_consumer do
    {:ok, workflow} =
      UseCaseFixtures.import_fixture("send_leads_email.json",
        swap: %{
          "draft_email" => UseCaseStubs.AgentStub,
          "send_email" => UseCaseStubs.NotifyEchoStub,
          "update_history" => UseCaseStubs.HistoryEchoStub,
          "update_sheet_row" => UseCaseStubs.UpdateSheetStub
        }
      )

    workflow
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp run_producer(producer) do
    source_event = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => %{}},
      "trace_id" => Ecto.UUID.generate()
    }

    Workflows.create_and_start_run(producer, source_event)
  end

  defp put_sheet(rows) do
    header = ["email", "name", "company", "active", "sequence"]

    data =
      Enum.map(rows, fn r ->
        [
          r["email"],
          r["name"],
          r["company"] || "Acme",
          if(r["active"], do: "TRUE", else: "FALSE"),
          to_string(r["sequence"])
        ]
      end)

    Application.put_env(:zaq, :e2e_lead_sheet_content, [header | data])
    on_exit(fn -> Application.delete_env(:zaq, :e2e_lead_sheet_content) end)
  end

  # Collects the `lead_identified` events dispatched during a producer run.
  defp collect_dispatched(key, timeout \\ 300) do
    receive do
      {:dispatched, ^key, event} -> [event | collect_dispatched(key, timeout)]
    after
      timeout -> []
    end
  end

  # Triggers the consumer directly with an event produced by the REAL DispatchEvent,
  # so build_history authorization can be asserted in isolation.
  defp trigger_consumer(lead, opts) do
    machine = Keyword.get(opts, :machine, false)

    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "craft_email", machine: machine},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@craft_email_key, event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()
  defp step_map(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  # ── Producer: sheet scan → Batch gating → machine dispatch ───────────────────

  describe "producer (identify leads)" do
    test "dispatches a machine lead_identified event for a qualifying row" do
      put_sheet([@lead])
      producer = create_producer()

      assert {:ok, run} = run_producer(producer)
      assert run.status == "completed"

      assert [event] = collect_dispatched(@lead_event_key)
      # The real DispatchEvent marked it a machine dispatch (`assigns.machine`), which
      # is what later grants the consumer's build_history its skip_permissions.
      assert event.assigns[:machine] == true
    end

    test "gates out an inactive row (check_active) — no dispatch" do
      put_sheet([%{@lead | "active" => false}])
      producer = create_producer()

      assert {:ok, run} = run_producer(producer)
      assert run.status == "completed"
      assert collect_dispatched(@lead_event_key) == []
    end

    test "gates out a maxed-out sequence row (check_email_state) — no dispatch" do
      put_sheet([%{@lead | "sequence" => 4}])
      producer = create_producer()

      assert {:ok, run} = run_producer(producer)
      assert run.status == "completed"
      assert collect_dispatched(@lead_event_key) == []
    end

    test "dispatches only for the qualifying rows in a mixed sheet" do
      put_sheet([
        @lead,
        %{@lead | "email" => "inactive@acme.com", "active" => false},
        %{@lead | "email" => "maxed@acme.com", "sequence" => 5},
        %{@lead | "email" => "ok2@acme.com", "sequence" => 2}
      ])

      producer = create_producer()

      assert {:ok, run} = run_producer(producer)
      assert run.status == "completed"

      dispatched = collect_dispatched(@lead_event_key)
      assert length(dispatched) == 2
    end
  end

  # ── Consumer: build_history authorization (the regression guard) ─────────────

  describe "consumer build_history authorization" do
    test "a machine craft_email dispatch authorizes build_history and suspends at HITL" do
      consumer = create_consumer()

      trigger_consumer(@lead, machine: true)

      run = latest_run(consumer)
      assert run != nil
      steps = step_map(run)

      assert steps["ensure_person"].status == "completed"
      assert steps["build_history"].status == "completed"

      # A real Person was created for the lead by the real ensure_person step.
      assert Repo.get_by(Person, email: @lead["email"]) != nil

      # The run suspends at the real human-in-the-loop review step.
      assert run.status == "waiting"
      assert steps["review_email"].status == "waiting"
      refute Map.has_key?(steps, "send_email")
    end

    test "without the machine marker, build_history fails :unauthorized" do
      consumer = create_consumer()

      trigger_consumer(@lead, machine: false)

      run = latest_run(consumer)
      assert run.status == "failed"

      steps = step_map(run)
      assert steps["ensure_person"].status == "completed"
      assert steps["build_history"].status == "failed"
      assert inspect(steps["build_history"].errors) =~ "unauthorized"

      # The pipeline halts at build_history — nothing downstream runs.
      refute Map.has_key?(steps, "draft_email")
      refute Map.has_key?(steps, "review_email")
    end
  end

  # ── Consumer: full pipeline through HITL ─────────────────────────────────────

  describe "consumer full pipeline" do
    test "approval resumes the run through send and the sheet write" do
      consumer = create_consumer()

      trigger_consumer(@lead, machine: true)
      run = latest_run(consumer)
      assert run.status == "waiting"

      c_steps = step_map(run)
      assert c_steps["draft_email"].status == "completed"
      assert c_steps["review_email"].status == "waiting"
      refute Map.has_key?(c_steps, "send_email")

      approval = Workflows.get_pending_approval(run.id)
      assert approval.step_name == "review_email"
      assert {:ok, _} = Workflows.approve_step(run, approval, %{}, "reviewer@acme.com")

      completed = Workflows.get_run(run.id)
      assert completed.status == "completed"

      after_steps = step_map(run)
      assert after_steps["send_email"].results["notified"] == true
      assert after_steps["update_history"].results["persisted"] == true
      assert after_steps["update_sheet_row"].results["status"] == "updated"
    end

    test "rejecting the review fails the run before sending" do
      consumer = create_consumer()

      trigger_consumer(@lead, machine: true)
      run = latest_run(consumer)
      assert run.status == "waiting"

      approval = Workflows.get_pending_approval(run.id)

      assert {:ok, _} =
               Workflows.reject_step(run, approval, "not a fit", "reviewer@acme.com")

      failed = Workflows.get_run(run.id)
      assert failed.status == "failed"

      steps = step_map(run)
      assert steps["review_email"].status == "failed"
      refute Map.has_key?(steps, "send_email")
    end
  end
end
