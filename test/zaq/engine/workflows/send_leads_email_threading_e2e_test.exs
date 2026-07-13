defmodule Zaq.Engine.Workflows.SendLeadsEmailThreadingE2ETest do
  @moduledoc """
  Step 8 — the actual guarantee.

  Runs the real `send_leads_email` DAG twice for the same lead and asserts that
  send 2's `In-Reply-To` **is** send 1's `Message-ID`. That single assertion is
  the whole feature: it is what makes Gmail put the two emails in one thread
  regardless of the days-long gap between them.

  ## What is real vs. stubbed

  `send_email` (NotifyPerson) and `update_history` (PersistMessageHistory) are
  **real** — they are the seam under test, so stubbing either would prove nothing.
  The mint, the anchor lookup, the edge mapping, and the persistence round trip all
  execute for real against the DB.

  Only the leaves outside our control are stubbed: the LLM draft, the Google Sheet
  write, and the final SMTP hop (captured at the `deliver_outgoing` boundary so we
  can inspect the `%Outgoing{}` that would have been sent).
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.UseCases.SendLeadsEmail

  @lead_event_key "engine:lead_identified"
  @topic "Acme × ZAQ — Q3 AI rollout"

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

  # ── Stubs: only the leaves ─────────────────────────────────────────

  defmodule DraftStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "draft_stub_e2e",
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
    def run(_params, _ctx), do: {:ok, %{output: "Hi there. Julien, ZAQ"}}
  end

  defmodule UpdateStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "update_stub_e2e",
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

  # Stands in for the SMTP hop: captures the %Outgoing{} the engine would deliver
  # and reports success, so the notification is marked :sent.
  defmodule DeliverCapturingRouter do
    @moduledoc false
    alias Zaq.Engine.Workflows.SendLeadsEmailThreadingE2ETest, as: Test

    def dispatch(event) do
      case event.opts[:action] do
        :bridge_available ->
          %{event | response: true}

        :deliver_outgoing ->
          # The request IS the %Outgoing{} the bridge would deliver.
          send(Test.collector(), {:sent, event.request})
          %{event | response: :ok}

        _ ->
          %{event | response: :ok}
      end
    end
  end

  # Routes the workflow's own events into the real engine.
  defmodule EngineRouter do
    @moduledoc false
    alias Zaq.Engine.Api

    def dispatch(%Zaq.Event{} = event) do
      case event.next_hop && event.next_hop.destination do
        :engine -> Api.handle_event(event, event.opts[:action], nil)
        _ -> %{event | response: :ok}
      end
    end
  end

  defmodule CaptureRouter do
    @moduledoc false
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:captured, event})
      event
    end
  end

  # The send happens inside the StepRunner process, not the test process, so the
  # collector pid must be reachable from anywhere.
  def collector, do: Application.get_env(:zaq, :e2e_threading_collector)

  # ── Setup ──────────────────────────────────────────────────────────

  setup do
    Application.put_env(:zaq, :e2e_threading_collector, self())
    on_exit(fn -> Application.delete_env(:zaq, :e2e_threading_collector) end)

    Mox.stub(Zaq.NodeRouterMock, :dispatch, &EngineRouter.dispatch/1)

    # Notifications resolves its own router; point it at the capturing stub so the
    # send is "delivered" without touching SMTP.
    Application.put_env(:zaq, :notifications_node_router_module, DeliverCapturingRouter)
    on_exit(fn -> Application.delete_env(:zaq, :notifications_node_router_module) end)

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

    :ok
  end

  defp create_consumer do
    build = [] |> SendLeadsEmail.build() |> swap_leaves()
    {:ok, workflow} = Workflows.create_workflow(build)
    {:ok, trigger} = Workflows.create_trigger(%{event_name: "lead_identified"})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)
    workflow
  end

  # send_email and update_history stay REAL — they are the seam under test.
  defp swap_leaves(build) do
    swaps = %{"draft_email" => DraftStub, "update_sheet_row" => UpdateStub}

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

  # Fires the DAG, then clears the real human-in-the-loop review gate so execution
  # continues into send_email. The review step stays real — we approve it, we don't
  # stub it away.
  defp run_workflow(workflow, lead) do
    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "lead_identified", machine: true},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@lead_event_key, event)

    # The run awaiting approval is this one — not simply the first in the list.
    run =
      workflow.id
      |> Workflows.list_runs()
      |> Enum.find(&Workflows.get_pending_approval(&1.id))

    assert run, "no run is awaiting approval — the DAG stopped before review_email"

    approval = Workflows.get_pending_approval(run.id)
    {:ok, _} = Workflows.approve_step(run, approval, %{}, "reviewer@acme.com")

    run
  end

  # The DAG has a 3-day recency gate: a lead is not emailed again while their last
  # message is fresh. Backdating the stored history is what makes send 2 a genuine
  # "days later" follow-up — and days apart is exactly the case Gmail's subject
  # heuristic fails on, which is why this feature exists.
  defp simulate_days_passing(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)

    from(m in Conversations.Message)
    |> Repo.update_all(set: [inserted_at: cutoff])
  end

  defp await_send(run \\ nil) do
    receive do
      {:sent, %Outgoing{} = outgoing} -> outgoing
    after
      2_000 -> flunk("no email was delivered.\n" <> step_report(run))
    end
  end

  defp step_report(nil), do: "(no run)"

  defp step_report(run) do
    run.id
    |> Workflows.list_step_runs()
    |> Enum.map_join("\n", fn s ->
      "  #{s.step_name}: #{s.status} #{inspect(s.error)}"
    end)
  end

  # ── The guarantee ──────────────────────────────────────────────────

  describe "two sends, days apart, one thread" do
    test "send 2's In-Reply-To is send 1's Message-ID" do
      workflow = create_consumer()

      # ── Send 1 ──────────────────────────────────────────────────
      run = run_workflow(workflow, @lead)
      first = await_send(run)

      m1 = first.metadata["email"]["threading"]["message_id"]

      assert is_binary(m1)
      assert m1 =~ ~r/@zaq\.test$/
      # A first send has nothing to reply to.
      assert first.in_reply_to == nil
      assert first.metadata["email"]["threading"]["references"] == []
      # It is the root of its own thread.
      assert first.thread_id == m1

      # The mint must have been persisted, or send 2 has nothing to anchor to.
      anchor = Conversations.email_thread_anchor(person_id(), @topic, @topic)
      assert anchor.message_id == m1

      # ── Send 2 (the lead sequence's next step, days later) ──────
      simulate_days_passing(4)
      run_workflow(workflow, Map.put(@lead, "sequence", 2))
      second = await_send()

      m2 = second.metadata["email"]["threading"]["message_id"]

      # THE GUARANTEE: send 2 replies to send 1.
      assert second.in_reply_to == m1
      assert second.metadata["email"]["threading"]["in_reply_to"] == m1
      # And References carries the ancestor, which is what Gmail groups on.
      assert m1 in second.metadata["email"]["threading"]["references"]
      # Same thread root → same Gmail thread.
      assert second.thread_id == m1

      # Send 2 is a distinct message that itself becomes the next anchor.
      refute m2 == m1
      assert Conversations.email_thread_anchor(person_id(), @topic, @topic).message_id == m2
    end

    test "both sends land in one conversation, and it stays topic-keyed" do
      workflow = create_consumer()

      run_workflow(workflow, @lead)
      await_send()
      simulate_days_passing(4)
      run_workflow(workflow, Map.put(@lead, "sequence", 2))
      await_send()

      convs =
        from(c in Conversations.Conversation, where: c.channel_type == "email:imap")
        |> Repo.all()

      assert [conv] = convs
      # Grouping stayed on the topic — the minted ids never re-keyed it.
      assert conv.channel_user_id == @topic

      assert Repo.aggregate(
               from(m in Conversations.Message, where: m.conversation_id == ^conv.id),
               :count
             ) == 2
    end

    test "the subject stays clean — threading comes from headers, not a Re: prefix" do
      workflow = create_consumer()

      run_workflow(workflow, @lead)
      await_send()
      simulate_days_passing(4)
      run_workflow(workflow, Map.put(@lead, "sequence", 2))
      second = await_send()

      assert second.metadata["subject"] == @topic
      refute second.metadata["subject"] =~ ~r/^Re:/i
    end
  end

  defp person_id do
    People.list_people()
    |> Enum.find(&(&1.email == "lead@acme.com"))
    |> Map.get(:id)
  end
end
