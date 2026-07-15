defmodule Zaq.Engine.Workflows.SendLeadsEmailThreadTest do
  @moduledoc """
  Guards the **single-thread subject invariant** of the real `Send Leads Email`
  workflow: every message ZAQ sends to a lead must carry the SAME subject — the
  fixed `email topic` delivered on the trigger payload (`start.email topic`) — so
  the outreach lands in one thread instead of spawning a fresh one each send.

  Two seams enforce the single thread, and both must read the same fixed topic via
  an edge mapping (not the node's static fallback):

    * `send_email`     (`NotifyPerson`)          — `subject` ← `start.email topic`
    * `update_history` (`PersistMessageHistory`) — `topic`   ← `start.email topic`

  ## What is real vs. stubbed

  The **full production workflow** is imported from
  `test/support/fixtures/workflows/send_leads_email.json` through the real
  `Workflows.import_workflow/1` path and run through the real engine — so
  `ensure_person`, the real `Accounts.History` (`build_history`, authorized by the
  machine dispatch), the recency `Condition`, the `Concat` agent-context build, the
  real `HumanInTheLoop` review, `Increment`, and the sheet-range `Concat`s all
  execute. Only the external boundaries are swapped: the LLM draft, the sheet write,
  and the two send/persist leaves — the latter as **echo** stubs so the test can
  read back the subject/topic the engine resolved.

  Runs `async: false`: the consumer is triggered through the real `DispatchEvent`
  → `TriggerNode.fire/2` seam, which needs the shared Ecto sandbox and Mox
  `$callers` propagation.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Test.{UseCaseFixtures, UseCaseStubs}

  @craft_email_key "engine:craft_email"

  # The fixed per-lead subject as it would arrive on the craft_email payload. It is
  # intentionally distinct from the node's static fallback subject so an assertion of
  # `subject == @topic` also proves the mapping — not the fallback — produced it.
  @topic "Acme × ZAQ — Q3 AI rollout"
  @fallback_subject "Your team's AI-powered company brain"

  # A production-shaped lead row. Every field is readable as `start.<field>`; the
  # threading-critical one is `email topic`.
  @lead %{
    "email" => "lead@acme.com",
    "name" => "John Doe",
    "email topic" => @topic,
    "language" => "english",
    "company official name" => "Acme Corp",
    "company context content" => "Acme Corp builds industrial IoT sensors.",
    "sequence" => 1,
    "row_index" => 2
  }

  # Captures the event the real DispatchEvent builds so the consumer can be
  # triggered directly (no producer DAG).
  defmodule CaptureRouter do
    @moduledoc false
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:captured, event})
      event
    end
  end

  setup do
    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  # Imports the real Send Leads Email workflow, stubbing only the external leaves.
  # send_email / update_history are echo stubs so the resolved subject/topic can be
  # read back.
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

  # Triggers the consumer with an event produced by the REAL DispatchEvent, marked
  # `machine: true` so the run carries skip_permissions and build_history resolves
  # the mapped person_id.
  defp trigger_consumer(lead) do
    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "craft_email", machine: true},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@craft_email_key, event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()
  defp step_map(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  describe "email threading" do
    test "send_email uses the fixed topic as subject and update_history reuses it" do
      consumer = create_consumer()

      # Trigger, draft, and suspend at the real human-in-the-loop review step.
      trigger_consumer(@lead)
      run = latest_run(consumer)
      assert run.status == "waiting"

      steps = step_map(run)
      assert steps["ensure_person"].status == "completed"
      assert steps["build_history"].status == "completed"
      assert steps["draft_email"].status == "completed"
      assert steps["review_email"].status == "waiting"

      # Approve → resume → run sends and persists history.
      approval = Workflows.get_pending_approval(run.id)
      assert {:ok, _} = Workflows.approve_step(run, approval, %{}, "reviewer@acme.com")

      completed = Workflows.get_run(run.id)
      assert completed.status == "completed"

      after_steps = step_map(run)

      # The subject the engine handed to NotifyPerson is the fixed topic — not the
      # draft body, not the static fallback. This is what keeps every send to this
      # lead in one email thread.
      assert after_steps["send_email"].results["subject"] == @topic
      refute after_steps["send_email"].results["subject"] == @fallback_subject

      # PersistMessageHistory records the message under the SAME topic, so the
      # conversation (email:imap keys by subject/topic) stays a single thread.
      assert after_steps["update_history"].results["topic"] == @topic
    end
  end
end
