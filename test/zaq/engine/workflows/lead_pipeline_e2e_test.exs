defmodule Zaq.Engine.Workflows.LeadPipelineE2ETest do
  @moduledoc """
  End-to-end coverage for the **real** two-workflow lead pipeline defined by
  `UseCases.IdentifyLeadsFromGoogleSheet` (producer) and `UseCases.SendLeadsEmail`
  (consumer).

  Unlike a fully-stubbed reproduction, this test builds both workflows from their
  *production* `build/1` definitions and runs them through the real engine. Only
  the unavoidable external boundaries are swapped for local stubs:

    * `get_sheet`        — Google datasource read → returns a fixture `%Record{}`
    * `draft_email`      — LLM agent call → returns a deterministic draft string
    * `send_email`       — notification dispatch → records the message
    * `update_sheet_row` — Google datasource write → records the update
    * `sleep_between`    — duration shortened to 0 so the run is instant

  Everything on the **authorization-critical path stays real**: the producer's
  `Condition` gating, the real `DispatchEvent` tool (which stamps the `machine`
  marker), `TriggerNode` (which translates it to `skip_permissions`), and the
  consumer's real `EnsurePerson` → `Accounts.History` (`build_history`) →
  `BuildSingleCellUpdate` → `HumanInTheLoop` steps.

  ## Why this matters

  `build_history` (`Accounts.History`) only honors the workflow-mapped `person_id`
  when the run carries `skip_permissions: true`. That flag is only set when the
  triggering `lead_identified` event carries `machine: true`, which the producer's
  `dispatch_lead` step must opt into. If that wiring regresses — the producer drops
  the `machine` flag, `DispatchEvent` stops propagating it, or `TriggerNode` stops
  translating it — `build_history` fails with `:unauthorized`. The
  "build_history authorization" describe block pins both the positive and negative
  cases so the regression is caught before production.

  Runs `async: false` because the producer triggers the consumer synchronously
  through `TriggerNode.fire/2` (a `Task.async_stream`), which needs the shared
  Ecto sandbox. The `NodeRouterMock` stub is inherited by the trigger Task via
  Mox `$callers` propagation.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.UseCases.{IdentifyLeadsFromGoogleSheet, SendLeadsEmail}

  @sheet_id "test-sheet-id"
  @lead_event_key "engine:lead_identified"

  @lead %{
    "email" => "john@acme.com",
    "name" => "John Doe",
    "company" => "Acme Corp",
    "active" => true,
    "email_state" => 1,
    "row_index" => 2
  }

  # ── External-boundary stubs ─────────────────────────────────────────────────
  #
  # Each honors the real tool's output contract so the production edges and
  # conditions still validate the wiring. They replace ONLY network/LLM calls;
  # every other node in both workflows is the real production module.

  # Google Sheets read. Returns the fixture rows configured per-test under the
  # :e2e_lead_sheet_content application env so the real `ExtractRows` parses them.
  defmodule GetSheetStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "get_sheet_stub",
      schema: [
        provider: [type: :string, required: true],
        spreadsheet_id: [type: :string, required: true],
        range: [type: :string, required: false],
        config_id: [type: :string, required: false]
      ],
      output_schema: [record: [type: :any, required: true]]

    @impl Jido.Action
    def run(_params, _ctx) do
      content = Application.get_env(:zaq, :e2e_lead_sheet_content, [])
      {:ok, %{record: %Zaq.Contracts.Record{id: "stub", kind: :sheet, content: content}}}
    end
  end

  # Bridges the producer's real `DispatchEvent` into the deterministic
  # `TriggerNode` seam. `StepRunner` does not inject a `node_router` into the step
  # context and the real `DispatchEvent` defaults to the live `Zaq.NodeRouter`, so
  # this wrapper injects the Mox router (whose stub fires `TriggerNode` in-process)
  # while delegating ALL machine-flag/request logic to the real tool.
  defmodule BridgeDispatchEvent do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "bridge_dispatch_event",
      schema: [
        input: [type: :map, required: true],
        event_name: [type: :string, required: true],
        machine: [type: :boolean, required: false, default: false]
      ],
      output_schema: [dispatched: [type: :map, required: true]]

    alias Zaq.Agent.Tools.Workflow.DispatchEvent

    @impl Jido.Action
    def run(params, ctx) do
      DispatchEvent.run(params, Map.put(ctx, :node_router, Zaq.NodeRouterMock))
    end
  end

  # LLM agent draft. Mirrors `RunAgent`'s `output` contract.
  defmodule DraftStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "draft_stub",
      schema: [
        agent_name: [type: :string, required: false],
        input: [type: :string, required: false],
        row: [type: :any, required: false]
      ],
      output_schema: [output: [type: :string, required: true]]

    @impl Jido.Action
    def run(params, _ctx) do
      row = params[:row] || params["row"] || %{}
      name = Map.get(row, "name") || Map.get(row, :name) || "there"
      company = Map.get(row, "company") || Map.get(row, :company) || "your company"
      {:ok, %{output: "Hi #{name}, excited to connect about #{company}."}}
    end
  end

  # Notification dispatch. Mirrors `NotifyPerson`'s contract; records the message.
  defmodule NotifyStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "notify_stub",
      schema: [
        person: [type: :any, required: false],
        subject: [type: :string, required: false],
        message: [type: :any, required: false]
      ],
      output_schema: [
        notified: [type: :boolean, required: true],
        status: [type: :any, required: false],
        sent_message: [type: :string, required: false]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      message = params[:message] || params["message"] || ""
      {:ok, %{notified: true, status: :dispatched, sent_message: to_string(message)}}
    end
  end

  # Google Sheets write. Mirrors `UpdateSheetValues`' status contract.
  defmodule UpdateStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "update_stub",
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

  # Captures the event the real `DispatchEvent` builds so the consumer can be
  # triggered directly (no producer DAG) for the focused authorization tests.
  defmodule CaptureRouter do
    @moduledoc false
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:captured, event})
      event
    end
  end

  # ── Setup ───────────────────────────────────────────────────────────────────

  setup do
    # The real `DispatchEvent` (via BridgeDispatchEvent) dispatches the
    # `lead_identified` event through this mock; route it into TriggerNode exactly
    # as the live EventRegistry would. Other events (workflow lifecycle) are no-ops.
    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      if trigger_key(event) == @lead_event_key do
        TriggerNode.fire(@lead_event_key, event)
      end

      event
    end)

    Application.put_env(:zaq, :e2e_lead_sheet_content, sheet_content([@lead]))
    on_exit(fn -> Application.delete_env(:zaq, :e2e_lead_sheet_content) end)

    :ok
  end

  # Mirrors EventRegistry: destination-prefix the base name unless already keyed.
  defp trigger_key(%{name: name, next_hop: %{destination: dest}})
       when is_binary(name) and is_atom(dest) do
    if String.contains?(name, ":"), do: name, else: "#{dest}:#{name}"
  end

  defp trigger_key(_), do: nil

  # ── Workflow fixtures (real definitions, boundaries swapped) ─────────────────

  defp create_producer do
    build =
      @sheet_id
      |> IdentifyLeadsFromGoogleSheet.build("google_drive")
      |> swap_producer_modules()

    {:ok, workflow} = Workflows.create_workflow(build)
    workflow
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

  # Swap get_sheet → stub, shorten sleep, and route the real DispatchEvent through
  # the bridge. extract_rows, the Condition gates, and the dispatch logic stay real.
  defp swap_producer_modules(build) do
    nodes =
      Enum.map(build.nodes, fn node ->
        cond do
          node_name(node) == "get_sheet" -> put_module(node, GetSheetStub)
          node[:type] == "map" or node["type"] == "map" -> patch_map_node(node)
          true -> node
        end
      end)

    %{build | nodes: nodes}
  end

  defp patch_map_node(node) do
    params = node[:params] || node["params"]

    body =
      Enum.map(params["body"] || [], fn bnode ->
        if node_name(bnode) == "dispatch_lead",
          do: put_module(bnode, BridgeDispatchEvent),
          else: bnode
      end)

    post =
      Enum.map(params["post_process"] || [], fn pnode ->
        if node_name(pnode) == "sleep_between",
          do: Map.put(pnode, "params", %{"duration_ms" => 0}),
          else: pnode
      end)

    params = params |> Map.put("body", body) |> Map.put("post_process", post)
    Map.put(node, :params, params)
  end

  # Swap the three external leaf steps; keep ensure_person, build_history,
  # build_sheet_update, and the real HumanInTheLoop review step.
  defp swap_consumer_modules(build) do
    swaps = %{
      "draft_email" => DraftStub,
      "send_email" => NotifyStub,
      "update_sheet_row" => UpdateStub
    }

    nodes =
      Enum.map(build.nodes, fn node ->
        case Map.get(swaps, node_name(node)) do
          nil -> node
          mod -> put_module(node, mod)
        end
      end)

    %{build | nodes: nodes}
  end

  defp node_name(node), do: node[:name] || node["name"]

  defp put_module(node, mod) do
    cond do
      Map.has_key?(node, :module) -> %{node | module: inspect(mod)}
      Map.has_key?(node, "module") -> Map.put(node, "module", inspect(mod))
      true -> node
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp sheet_content(rows) do
    header = ["email", "name", "company", "active", "email_state"]

    data =
      Enum.map(rows, fn r ->
        [
          r["email"],
          r["name"],
          r["company"],
          if(r["active"], do: "TRUE", else: "FALSE"),
          to_string(r["email_state"])
        ]
      end)

    [header | data]
  end

  defp run_producer(producer) do
    source_event = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "input" => %{}},
      "trace_id" => Ecto.UUID.generate()
    }

    Workflows.create_and_start_run(producer, source_event)
  end

  # Triggers the consumer directly with an event produced by the REAL DispatchEvent
  # (capturing it), so build_history authorization can be asserted in isolation.
  defp trigger_consumer(lead, opts) do
    machine = Keyword.get(opts, :machine, false)

    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "lead_identified", machine: machine},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@lead_event_key, event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()

  defp step_map(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  # ── build_history authorization (the regression guard) ───────────────────────

  describe "build_history authorization" do
    test "machine-marked dispatch lets build_history resolve the lead and suspend at HITL" do
      consumer = create_consumer()

      trigger_consumer(@lead, machine: true)

      run = latest_run(consumer)
      assert run != nil
      steps = step_map(run)

      # The previously-failing step now completes: ensure_person created the lead,
      # build_history authorized via the machine-granted skip_permissions.
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

  # ── Producer definition guard ────────────────────────────────────────────────

  describe "producer definition" do
    test "dispatch_lead opts into a machine dispatch" do
      build = IdentifyLeadsFromGoogleSheet.build(@sheet_id)

      map_node = Enum.find(build.nodes, &(&1[:type] == "map"))
      dispatch_node = Enum.find(map_node.params["body"], &(&1["name"] == "dispatch_lead"))

      assert dispatch_node["params"]["machine"] == true,
             "dispatch_lead must set machine: true so SendLeadsEmail's build_history is authorized"
    end
  end

  # ── Full pipeline ────────────────────────────────────────────────────────────

  describe "qualifying lead → real producer → real consumer → HITL approval" do
    test "producer dispatches, consumer drafts + suspends, approval completes it" do
      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, producer_run} = run_producer(producer)
      assert producer_run.status == "completed"

      # Consumer: triggered by the real dispatched event, ran the real
      # ensure_person + build_history (authorized), drafted, and suspended at HITL.
      consumer_run = latest_run(consumer)
      assert consumer_run != nil
      assert consumer_run.status == "waiting"

      c_steps = step_map(consumer_run)
      assert c_steps["ensure_person"].status == "completed"
      assert c_steps["build_history"].status == "completed"
      assert c_steps["draft_email"].status == "completed"
      assert c_steps["draft_email"].results["output"] =~ "John Doe"
      assert c_steps["draft_email"].results["output"] =~ "Acme Corp"
      assert c_steps["review_email"].status == "waiting"
      refute Map.has_key?(c_steps, "send_email")

      # Human-in-the-loop approval record exists for the real review step.
      approval = Workflows.get_pending_approval(consumer_run.id)
      assert approval != nil
      assert approval.step_name == "review_email"

      # Approve → resume → complete through send + the real sheet-update build.
      assert {:ok, _} = Workflows.approve_step(consumer_run, approval, %{}, "reviewer@acme.com")

      completed = Workflows.get_run(consumer_run.id)
      assert completed.status == "completed"

      after_steps = step_map(consumer_run)
      assert after_steps["review_email"].status == "completed"
      assert after_steps["review_email"].results["approved"] == true
      assert after_steps["send_email"].status == "completed"
      assert after_steps["send_email"].results["notified"] == true
      assert after_steps["send_email"].results["sent_message"] =~ "John Doe"
      # The real BuildSingleCellUpdate ran and the (stubbed) sheet write recorded it.
      assert after_steps["build_sheet_update"].status == "completed"
      assert after_steps["update_sheet_row"].status == "completed"
      assert after_steps["update_sheet_row"].results["status"] == "updated"
    end

    test "rejecting the HITL review fails the consumer run before sending" do
      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, _producer_run} = run_producer(producer)

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

  # ── Non-qualifying lead ──────────────────────────────────────────────────────

  describe "non-qualifying lead" do
    test "producer completes without dispatching and no consumer run is created" do
      Application.put_env(
        :zaq,
        :e2e_lead_sheet_content,
        sheet_content([%{@lead | "active" => false}])
      )

      producer = create_producer()
      consumer = create_consumer()

      assert {:ok, producer_run} = run_producer(producer)
      assert producer_run.status == "completed"

      assert latest_run(consumer) == nil
    end
  end
end
