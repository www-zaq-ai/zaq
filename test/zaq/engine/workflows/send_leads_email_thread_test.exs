defmodule Zaq.Engine.Workflows.SendLeadsEmailThreadTest do
  @moduledoc """
  Guards the **email-threading invariant** of the real `UseCases.SendLeadsEmail`
  consumer: every message ZAQ sends to a lead must carry the SAME subject — the
  fixed `email topic` taken from the Google Sheet row (`start.email topic`) — so
  the outreach lands in one email thread instead of spawning a fresh thread on
  every send.

  Two seams enforce the single thread, and both must read the same fixed topic:

    * `send_email`     (`NotifyPerson`)          — `subject` ← `start.email topic`
    * `update_history` (`PersistMessageHistory`) — `topic`   ← `start.email topic`

  The subject is deliberately NOT derived from the agent draft (the draft prompt
  writes the BODY only) and must NOT fall back to the static placeholder when the
  row actually carries a topic. If the `review_email → send_email` edge is ever
  rewired to map `subject` from `draft_email.output` — or the mapping is dropped
  so it silently falls back — consecutive emails to a lead get different subjects
  and break into separate threads. This test pins that regression.

  ## What is real vs. stubbed

  It builds the **production** `SendLeadsEmail.build/1` and runs it through the
  real engine, so the real edge mappings resolve `start.email topic`. Only the
  unavoidable external leaves are swapped, and the `send_email`/`update_history`
  stubs **echo** the subject/topic they receive into their output so the
  assertions read the value the engine actually resolved:

    * `draft_email`      — LLM agent call → deterministic body
    * `send_email`       — notification dispatch → echoes the resolved `subject`
    * `update_history`   — history persistence → echoes the resolved `topic`
    * `update_sheet_row` — Google datasource write → records the update

  `ensure_person`, `build_history`, the recency `Condition`, the `Concat` nodes,
  the real `HumanInTheLoop` review, and `Increment` all stay real.

  Runs `async: false`: the consumer is triggered through the real `DispatchEvent`
  → `TriggerNode.fire/2` seam (a `Task`), which needs the shared Ecto sandbox and
  Mox `$callers` propagation.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.UseCases.SendLeadsEmail

  @lead_event_key "engine:lead_identified"

  # The fixed per-lead subject as it would arrive from the Google Sheet row. It is
  # intentionally distinct from SendLeadsEmail's static fallback subject so an
  # assertion of `subject == @topic` also proves the mapping — not the fallback —
  # produced it.
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

  # ── External-boundary stubs (echo the resolved values) ──────────────────────

  # LLM agent draft — writes only the BODY (no subject line), mirroring the real
  # RunAgent output contract and the SendLeadsEmail draft prompt.
  defmodule DraftStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "draft_stub_thread",
      schema: [
        agent_id: [type: :integer, required: false],
        input: [type: :string, required: false],
        name: [type: :any, required: false],
        company: [type: :any, required: false],
        language: [type: :any, required: false],
        context: [type: :any, required: false]
      ],
      output_schema: [output: [type: :string, required: true]]

    @impl Jido.Action
    def run(_params, _ctx),
      do: {:ok, %{output: "Hi there, ZAQ can help Acme automate its brain. Julien, ZAQ"}}
  end

  # Notification dispatch — echoes the subject the engine resolved so the test can
  # assert it. Mirrors NotifyPerson's `notified` contract otherwise.
  defmodule NotifyEchoStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "notify_echo_stub",
      schema: [
        person: [type: :any, required: false],
        subject: [type: :string, required: true],
        message: [type: :any, required: false]
      ],
      output_schema: [
        notified: [type: :boolean, required: true],
        status: [type: :any, required: false],
        subject: [type: :string, required: false]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      {:ok,
       %{notified: true, status: :dispatched, subject: params[:subject] || params["subject"]}}
    end
  end

  # History persistence — echoes the topic the engine resolved. Mirrors
  # PersistMessageHistory's output contract otherwise.
  defmodule HistoryEchoStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "history_echo_stub",
      schema: [
        person: [type: :any, required: false],
        topic: [type: :any, required: false],
        message: [type: :any, required: false],
        sent_message: [type: :any, required: false],
        subject: [type: :any, required: false]
      ],
      output_schema: [
        persisted: [type: :boolean, required: true],
        conversation_id: [type: :string, required: true],
        message_id: [type: :string, required: true],
        topic: [type: :any, required: false]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      {:ok,
       %{
         persisted: true,
         conversation_id: "stub-conv",
         message_id: "stub-msg",
         topic: params[:topic] || params["topic"]
       }}
    end
  end

  # Google Sheets write — records the update; mirrors UpdateSheetValues' status.
  defmodule UpdateStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "update_stub_thread",
      schema: [
        provider: [type: :string, required: false],
        spreadsheet_id: [type: :string, required: false],
        range: [type: :any, required: false],
        values: [type: :any, required: false],
        value_input_option: [type: :string, required: false]
      ],
      output_schema: [status: [type: :string, required: true]]

    @impl Jido.Action
    def run(_params, _ctx), do: {:ok, %{status: "updated"}}
  end

  # Captures the event the real DispatchEvent builds so the consumer can be
  # triggered directly (no producer DAG).
  defmodule CaptureRouter do
    @moduledoc false
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:captured, event})
      event
    end
  end

  # ── Setup ───────────────────────────────────────────────────────────────────

  setup do
    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
    :ok
  end

  defp create_consumer do
    build =
      []
      |> SendLeadsEmail.build()
      |> swap_consumer_modules()

    {:ok, workflow} = Workflows.create_workflow(build)
    {:ok, trigger} = Workflows.create_trigger(%{event_name: "lead_identified"})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)
    workflow
  end

  # Swap only the external leaves; keep ensure_person, build_history, the recency
  # Condition, the Concat nodes, the real HumanInTheLoop, and Increment real.
  defp swap_consumer_modules(build) do
    swaps = %{
      "draft_email" => DraftStub,
      "send_email" => NotifyEchoStub,
      "update_history" => HistoryEchoStub,
      "update_sheet_row" => UpdateStub
    }

    nodes =
      Enum.map(build.nodes, fn node ->
        case Map.get(swaps, node[:name] || node["name"]) do
          nil -> node
          mod -> put_module(node, mod)
        end
      end)

    %{build | nodes: nodes}
  end

  defp put_module(node, mod) do
    cond do
      Map.has_key?(node, :module) -> %{node | module: inspect(mod)}
      Map.has_key?(node, "module") -> Map.put(node, "module", inspect(mod))
      true -> node
    end
  end

  # Triggers the consumer with an event produced by the REAL DispatchEvent, marked
  # `machine: true` so the run carries skip_permissions and build_history resolves
  # the mapped person_id (mirrors the producer's dispatch_lead).
  defp trigger_consumer(lead) do
    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "lead_identified", machine: true},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@lead_event_key, event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()
  defp step_map(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  # ── Definition guard (fast, catches a rewire even if the engine changes) ──────

  describe "workflow definition" do
    test "send_email subject and update_history topic both map the fixed sheet email topic" do
      build = SendLeadsEmail.build()

      send_edge = Enum.find(build.edges, &(&1.from == "review_email" and &1.to == "send_email"))

      history_edge =
        Enum.find(build.edges, &(&1.from == "send_email" and &1.to == "update_history"))

      assert send_edge.mapping["subject"] == "start.email topic",
             "send_email subject must come from the fixed sheet topic (same thread), not the draft"

      assert history_edge.mapping["topic"] == "start.email topic",
             "update_history topic must come from the same fixed sheet topic so messages group in one thread"
    end
  end

  # ── End-to-end resolution (real engine resolves start.email topic) ────────────

  describe "email threading" do
    test "send_email uses the fixed sheet topic as subject and update_history reuses it" do
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

      # The subject the engine handed to NotifyPerson is the fixed sheet topic —
      # not the agent body, not the static fallback. This is what keeps every
      # send to this lead in one email thread.
      assert after_steps["send_email"].results["subject"] == @topic
      refute after_steps["send_email"].results["subject"] == @fallback_subject

      # PersistMessageHistory records the message under the SAME topic, so the BO
      # conversation (email:imap keys by subject/topic) stays a single thread.
      assert after_steps["update_history"].results["topic"] == @topic
    end
  end
end
