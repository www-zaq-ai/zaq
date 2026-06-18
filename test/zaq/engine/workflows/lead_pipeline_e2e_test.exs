defmodule Zaq.Engine.Workflows.LeadPipelineE2ETest do
  @moduledoc """
  End-to-end coverage for the two-workflow lead pipeline scenario currently
  demonstrated by the `UseCases.IdentifyLeadsFromGoogleSheet` /
  `UseCases.SendLeadsEmail` example modules (which are slated for removal).

  This test reproduces the same behaviour with self-contained stub actions so the
  scenario keeps being verified after the examples are deleted. It exercises, in
  one real run through the engine:

    1. **Workflow → event → workflow.** A *producer* workflow run dispatches a
       `lead_identified` engine event for a qualifying lead. The stubbed
       `NodeRouter` routes that event through `TriggerNode.fire/2` exactly as the
       live `EventRegistry` would, which creates and starts the *consumer*
       workflow run. A non-qualifying lead is gated out by an edge condition and
       never dispatches.

    2. **LLM stub drafting a message.** The consumer's first step stands in for a
       `RunAgent` call: it returns an `output` string (the drafted email),
       matching the agent action's output contract without touching an LLM.

    3. **Human-in-the-loop verification.** The consumer suspends at a real
       `Steps.HumanInTheLoop` node (`waiting`), creating a `StepApproval`.
       Approving via `Workflows.approve_step/5` resumes the run to completion and
       the drafted message flows through the approval gate into the send step;
       rejecting via `reject_step/5` fails the run before anything is sent.

  Runs `async: false` because the producer triggers the consumer synchronously
  through `TriggerNode.fire/2` (a `Task.async_stream`), which needs the shared
  Ecto sandbox. The `NodeRouterMock` stub is inherited by the trigger Task via
  Mox `$callers` propagation.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Steps.HumanInTheLoop

  # ── Stub actions ──────────────────────────────────────────────────────────

  # Producer step 1: surfaces `active` for the qualifying edge and re-exposes the
  # full lead row under `input` for the dispatch step.
  defmodule QualifyLead do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "qualify_lead_e2e",
      schema: [email: [type: :any, required: false]],
      output_schema: [
        input: [type: :map, required: true],
        active: [type: :boolean, required: true]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      row =
        params
        |> Map.drop([:__cascade__, "__cascade__"])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      active = Map.get(params, "active") || Map.get(params, :active) || false
      {:ok, %{input: row, active: active == true}}
    end
  end

  # Producer step 2: dispatches the lead as a `lead_identified` engine event
  # through the configured NodeRouter (the same indirection the real
  # `Tools.Workflow.DispatchEvent` uses).
  defmodule DispatchLead do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "dispatch_lead_e2e",
      schema: [input: [type: :map, required: true]],
      output_schema: [dispatched: [type: :map, required: true]]

    @impl Jido.Action
    def run(params, _ctx) do
      row = Map.get(params, :input) || Map.get(params, "input") || %{}
      request = Map.new(row, fn {k, v} -> {to_string(k), v} end)
      event = Zaq.Event.new(request, :engine, type: :async, name: "lead_identified")

      node_router = Application.get_env(:zaq, :node_router, Zaq.NodeRouter)
      node_router.dispatch(event)

      {:ok, %{dispatched: request}}
    end
  end

  # Consumer step 1: LLM stub. Mirrors `Tools.Workflow.RunAgent`'s `output`
  # contract — drafts a message from the lead row without invoking a model.
  defmodule DraftAgent do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "draft_agent_e2e",
      schema: [email: [type: :any, required: false]],
      output_schema: [output: [type: :string, required: true]]

    @impl Jido.Action
    def run(params, _ctx) do
      name = Map.get(params, "name") || Map.get(params, :name) || "there"
      company = Map.get(params, "company") || Map.get(params, :company) || "your company"
      {:ok, %{output: "Hi #{name}, excited to connect about #{company}."}}
    end
  end

  # Consumer final step: records the approved, drafted message that would be sent.
  defmodule SendLead do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "send_lead_e2e",
      schema: [message: [type: :any, required: true]],
      output_schema: [
        notified: [type: :boolean, required: true],
        sent_message: [type: :string, required: true]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      message = Map.get(params, :message) || Map.get(params, "message")
      {:ok, %{notified: true, sent_message: message}}
    end
  end

  @lead %{
    "name" => "John Doe",
    "email" => "john@acme.com",
    "company" => "Acme Corp",
    "active" => true,
    "email_state" => 1
  }

  # NodeRouter stub: routes a dispatched `lead_identified` event into TriggerNode
  # (as the live EventRegistry would) and is a no-op for every other event
  # (workflow lifecycle, etc.).
  #
  # `create_trigger/1` namespaces the event name by destination role, so a
  # `lead_identified` event dispatched to `:engine` is keyed `engine:lead_identified`
  # — the same key `EventRegistry.derive_event_key/1` produces at runtime.
  @lead_event_key "engine:lead_identified"

  setup do
    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      if trigger_key(event) == @lead_event_key do
        TriggerNode.fire(@lead_event_key, event)
      end

      event
    end)

    :ok
  end

  # Mirrors EventRegistry: destination-prefix the base name unless already keyed.
  defp trigger_key(%{name: name, next_hop: %{destination: dest}})
       when is_binary(name) and is_atom(dest) do
    if String.contains?(name, ":"), do: name, else: "#{dest}:#{name}"
  end

  defp trigger_key(_), do: nil

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp create_producer do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Identify Leads E2E #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{name: "qualify", type: "action", module: inspect(QualifyLead), params: %{}, index: 0},
          %{
            name: "dispatch_lead",
            type: "action",
            module: inspect(DispatchLead),
            params: %{},
            index: 1
          }
        ],
        edges: [
          %{
            from: "qualify",
            to: "dispatch_lead",
            condition: %{"field" => "active", "op" => "eq", "value" => true}
          }
        ]
      })

    workflow
  end

  defp create_consumer do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Send Leads Email E2E #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "draft_email",
            type: "action",
            module: inspect(DraftAgent),
            params: %{},
            index: 0
          },
          %{
            name: "review_email",
            type: "action",
            module: inspect(HumanInTheLoop),
            params: %{"message" => "Review and approve the drafted lead email."},
            index: 1
          },
          %{name: "send_email", type: "action", module: inspect(SendLead), params: %{}, index: 2}
        ],
        edges: [
          %{
            from: "draft_email",
            to: "review_email",
            condition: %{"field" => "output", "op" => "not_empty"}
          },
          %{
            from: "review_email",
            to: "send_email",
            condition: %{"field" => "approved", "op" => "eq", "value" => true},
            mapping: %{"message" => "draft_email.output"}
          }
        ]
      })

    {:ok, trigger} = Workflows.create_trigger(%{event_name: "lead_identified", enabled: true})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    workflow
  end

  defp run_producer(producer, lead) do
    source_event = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => lead},
      "trace_id" => Ecto.UUID.generate()
    }

    Workflows.create_and_start_run(producer, source_event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()

  defp step_map(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  # ── Scenarios ───────────────────────────────────────────────────────────────

  describe "qualifying lead → cross-workflow dispatch + HITL approval" do
    test "producer dispatches, consumer drafts + suspends, approval completes it" do
      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, producer_run} = run_producer(producer, @lead)
      assert producer_run.status == "completed"

      # Producer: qualifying edge passed, lead dispatched.
      p_steps = step_map(producer_run)
      assert p_steps["qualify"].status == "completed"
      assert p_steps["dispatch_lead"].status == "completed"
      assert p_steps["dispatch_lead"].results["dispatched"]["email"] == "john@acme.com"

      # Consumer: triggered by the event, drafted, and suspended at HITL.
      consumer_run = latest_run(consumer)
      assert consumer_run != nil
      assert consumer_run.status == "waiting"

      c_steps = step_map(consumer_run)
      assert c_steps["draft_email"].status == "completed"
      assert c_steps["draft_email"].results["output"] =~ "John Doe"
      assert c_steps["draft_email"].results["output"] =~ "Acme Corp"
      assert c_steps["review_email"].status == "waiting"
      refute Map.has_key?(c_steps, "send_email")

      # Human-in-the-loop approval record exists.
      approval = Workflows.get_pending_approval(consumer_run.id)
      assert approval != nil
      assert approval.step_name == "review_email"

      # Approve → resume → complete.
      assert {:ok, _} = Workflows.approve_step(consumer_run, approval, %{}, "reviewer@acme.com")

      completed = Workflows.get_run(consumer_run.id)
      assert completed.status == "completed"

      after_steps = step_map(consumer_run)
      assert after_steps["review_email"].status == "completed"
      assert after_steps["review_email"].results["approved"] == true
      assert after_steps["send_email"].status == "completed"
      assert after_steps["send_email"].results["notified"] == true
      # The drafted message flowed through the approval gate into the send step.
      assert after_steps["send_email"].results["sent_message"] =~ "John Doe"
    end

    test "rejecting the HITL review fails the consumer run before sending" do
      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, _producer_run} = run_producer(producer, @lead)

      consumer_run = latest_run(consumer)
      assert consumer_run.status == "waiting"

      approval = Workflows.get_pending_approval(consumer_run.id)

      assert {:ok, _} =
               Workflows.reject_step(consumer_run, approval, "not a fit", "reviewer@acme.com")

      failed = Workflows.get_run(consumer_run.id)
      assert failed.status == "failed"

      steps = step_map(consumer_run)
      assert steps["review_email"].status == "failed"
      refute Map.has_key?(steps, "send_email")
    end
  end

  describe "non-qualifying lead" do
    test "producer completes without dispatching and no consumer run is created" do
      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, producer_run} = run_producer(producer, Map.put(@lead, "active", false))
      assert producer_run.status == "completed"

      p_steps = step_map(producer_run)
      assert p_steps["qualify"].status == "completed"
      # Qualifying edge gated out the dispatch.
      assert p_steps["qualify__to__dispatch_lead__edge"].status == "skipped"
      refute Map.has_key?(p_steps, "dispatch_lead")

      # Consumer was never triggered.
      assert Workflows.list_runs(consumer.id) == []
    end
  end
end
