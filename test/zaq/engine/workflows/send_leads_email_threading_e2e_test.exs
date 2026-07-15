defmodule Zaq.Engine.Workflows.SendLeadsEmailThreadingE2ETest do
  @moduledoc """
  The email-threading guarantee.

  Imports the **real Send Leads Email workflow** from
  `test/support/fixtures/workflows/send_leads_email.json`, runs it twice for the
  same lead, and asserts that send 2's `In-Reply-To` **is** send 1's `Message-ID`.
  That single assertion is the whole feature: it is what makes Gmail put the two
  emails in one thread regardless of the days-long gap between them.

  ## What is real vs. stubbed

  `send_email` (NotifyPerson) and `update_history` (PersistMessageHistory) are
  **real** — they are the seam under test, so stubbing either would prove nothing.
  The mint, the anchor lookup, the edge mapping, and the persistence round trip all
  execute for real against the DB. So does everything else on the path — the real
  `EnsurePerson`, `Accounts.History`, the recency `Condition` (which is what
  `simulate_days_passing/1` below actually exercises), the agent-context `Concat`,
  the real `HumanInTheLoop` review, `Increment`, and the sheet-range `Concat`s.

  Only the true external boundaries are stubbed: the LLM draft, the Google Sheet
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
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Engine.Workflows.Test.{UseCaseFixtures, UseCaseStubs}

  @craft_email_key "engine:craft_email"
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

  # ── Stubs: only the SMTP hop ───────────────────────────────────────

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

  # Imports the REAL Send Leads Email workflow. `send_email` (NotifyPerson) and
  # `update_history` (PersistMessageHistory) stay real — they are the threading seam
  # under test. Only the LLM draft and the sheet write are stubbed; every other node
  # (ensure_person, build_history, the recency Condition, agent-context Concat, the
  # HumanInTheLoop review, Increment, the sheet-range Concats) runs for real.
  defp create_consumer do
    {:ok, workflow} =
      UseCaseFixtures.import_fixture("send_leads_email.json",
        swap: %{
          "draft_email" => UseCaseStubs.AgentStub,
          "update_sheet_row" => UseCaseStubs.UpdateSheetStub
        }
      )

    workflow
  end

  # Fires the workflow through the real DispatchEvent → TriggerNode.fire seam, then
  # clears the real human-in-the-loop review gate so execution continues into
  # send_email. The review step stays real — we approve it, we don't stub it away.
  defp run_workflow(workflow, lead) do
    {:ok, _} =
      DispatchEvent.run(
        %{input: lead, event_name: "craft_email", machine: true},
        %{node_router: CaptureRouter}
      )

    assert_received {:captured, %Zaq.Event{} = event}
    TriggerNode.fire(@craft_email_key, event)

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

      # The mint must have been recorded on the notification log (the anchor the
      # real send path resolves first), or send 2 has nothing to anchor to.
      anchor = NotificationLog.thread_anchor(person_id(), @topic)
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
      assert NotificationLog.thread_anchor(person_id(), @topic).message_id == m2
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
