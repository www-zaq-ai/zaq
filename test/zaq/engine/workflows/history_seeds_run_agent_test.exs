defmodule Zaq.Engine.Workflows.HistorySeedsRunAgentTest do
  @moduledoc """
  End-to-end proof of the unified history → run_agent seam:

    1. `build_history` (`Accounts.History`) recalls conversations, scoped by
       `search_in: "title"`, and emits a flattened `messages` field in the unified
       `role`/`content` vocabulary.
    2. An edge `mapping` wires that `messages` list into `run_agent`'s `context`.
    3. `run_agent` normalises those `role`/`content` turns and carries them onto the
       dispatched `%Incoming{}` as `metadata.context_messages` — the agent's seed
       context.

  The run is a machine run (`skip_permissions`), so `build_history` searches across
  people and the only scoping is the title query. The `run_agent` dispatch is
  intercepted by a capture router injected through the run's opts (the non-env
  `StepRunner` node-router seam), so we can assert exactly what reached the agent
  without a live target.

  `async: false` because it drives a synchronous run and reads the capture pid from
  app env.
  """
  use Zaq.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Workflows

  # Intercepts run_agent's `:run_pipeline` dispatch, forwards the carried
  # %Incoming{} to the test, and returns a canned %Outgoing{} so the run completes
  # without a live agent. Any other event is delegated to the real router.
  defmodule CaptureIncomingRouter do
    @moduledoc false
    alias Zaq.Engine.Messages.{Incoming, Outgoing}

    def dispatch(%Zaq.Event{request: %Incoming{} = incoming, opts: opts} = event) do
      if Keyword.get(opts, :action) == :run_pipeline do
        pid = Application.get_env(:zaq, :history_seeds_capture_pid)
        if is_pid(pid), do: send(pid, {:captured_incoming, incoming})

        %{
          event
          | response: %Outgoing{body: "captured", channel_id: incoming.channel_id, provider: nil}
        }
      else
        Zaq.NodeRouter.dispatch(event)
      end
    end

    def dispatch(%Zaq.Event{} = event), do: Zaq.NodeRouter.dispatch(event)
  end

  setup do
    # Workflow lifecycle events (create/run.started …) dispatch through the mocked
    # router; pass them through. run_agent uses the injected CaptureIncomingRouter.
    set_mox_global()
    stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    Application.put_env(:zaq, :history_seeds_capture_pid, self())
    on_exit(fn -> Application.delete_env(:zaq, :history_seeds_capture_pid) end)
    :ok
  end

  defp create_person(email) do
    {:ok, person} = People.create_person(%{full_name: "History Person", email: email})
    person
  end

  defp create_conversation(person_id, title) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "u_#{System.unique_integer([:positive])}",
        person_id: person_id,
        title: title
      })

    conv
  end

  defp add_message(conv, role, content, inserted_at) do
    {:ok, message} = Conversations.add_message(conv, %{role: role, content: content})

    {1, _} =
      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: inserted_at]
      )

    message
  end

  # Machine run: `skip_permissions` lets `build_history` search across people, so the
  # title query is the only scoping under test.
  defp machine_source_event do
    %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual", "skip_permissions" => true},
      "trace_id" => Ecto.UUID.generate()
    }
  end

  test "build_history (search_in title) seeds run_agent context with the matching conversations' messages" do
    person = create_person("history_seed@example.com")

    falcon_launch = create_conversation(person.id, "Falcon launch plan")
    standup = create_conversation(person.id, "Weekly standup")
    falcon_retro = create_conversation(person.id, "Falcon retrospective")

    # Title-matched turns (chronological across the two Falcon conversations).
    add_message(falcon_launch, "user", "let us launch Falcon", ~U[2026-06-01 09:00:00.000000Z])
    # Excluded: its title carries no "Falcon", so the content never reaches the agent.
    add_message(standup, "user", "daily standup notes", ~U[2026-06-01 09:30:00.000000Z])
    add_message(falcon_retro, "assistant", "Falcon shipped well", ~U[2026-06-01 10:00:00.000000Z])

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "History Seeds RunAgent #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "build_history",
            type: "action",
            module: "Zaq.Agent.Tools.Accounts.History",
            params: %{"query" => "Falcon", "search_in" => "title"},
            index: 0
          },
          %{
            name: "run_agent",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{"agent_id" => 4242, "input" => "summarise my Falcon history"},
            index: 1
          }
        ],
        # The history node's flattened `messages` list is wired straight into
        # run_agent's `context` — the whole point of the unification.
        edges: [
          %{from: "build_history", to: "run_agent", mapping: %{"context" => "messages"}}
        ]
      })

    assert {:ok, run} =
             Workflows.create_and_start_run(workflow, machine_source_event(), %{},
               node_router: CaptureIncomingRouter
             )

    assert run.status == "completed"

    assert_received {:captured_incoming, incoming}

    # Only the two title-matched conversations' messages reach the agent, in
    # chronological order, as unified role/content turns.
    assert [
             %{role: "user", content: "let us launch Falcon"},
             %{role: "assistant", content: "Falcon shipped well"}
           ] = incoming.metadata[:context_messages]

    # The standup conversation (no "Falcon" in its title) is never seeded.
    contents = Enum.map(incoming.metadata[:context_messages], & &1.content)
    refute "daily standup notes" in contents
  end
end
