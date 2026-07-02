defmodule Zaq.Agent.Tools.People.NotifyPersonTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.People.EnsurePerson
  alias Zaq.Agent.Tools.People.NotifyPerson

  defmodule OkRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})
      %{event | response: {:ok, :dispatched}}
    end
  end

  defmodule SkippedRouter do
    def dispatch(event), do: %{event | response: {:ok, :skipped}}
  end

  defmodule ErrorRouter do
    def dispatch(event), do: %{event | response: {:error, "person_not_found:123"}}
  end

  defmodule StructuredErrorRouter do
    def dispatch(event), do: %{event | response: {:error, {:provider_failed, :timeout}}}
  end

  defmodule UnexpectedRouter do
    def dispatch(event), do: %{event | response: {:ok, :queued}}
  end

  describe "schema/0" do
    test "does not expose channel or sheet-specific fields" do
      keys = Keyword.keys(NotifyPerson.schema())

      assert :person in keys
      assert :subject in keys
      assert :message in keys
      refute :person_id in keys
      refute :medium in keys
      refute :row_index in keys
      refute :email_state in keys
      refute :email_state_column in keys
    end
  end

  describe "run/2" do
    test "dispatches a notify_person event to the engine" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :dispatched}} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :notify_person
      assert event.request == %{person_id: person.id, subject: "Hello", message: "Body"}
    end

    test "treats skipped notifications as successful no-op dispatches" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :skipped}} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: SkippedRouter}
               )
    end

    test "returns engine notification errors" do
      person = person_fixture()

      assert {:error, "person_not_found:123"} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: ErrorRouter}
               )
    end

    test "formats non-binary engine errors for action callers" do
      person = person_fixture()

      assert {:error, "{:provider_failed, :timeout}"} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: StructuredErrorRouter}
               )
    end

    # Shown verbatim in the BO run view (StepRunner stores binary reasons
    # untouched), so an unexpected response must read as prose — never the
    # `notify_person_failed:<inspect dump>` slug.
    test "describes an unexpected engine response in prose" do
      person = person_fixture()

      assert {:error, reason} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: UnexpectedRouter}
               )

      assert reason =~ "Notify person failed:"
      assert reason =~ "{:ok, :queued}"
      refute reason =~ "notify_person_failed:"
    end

    test "explains a missing/unresolvable person id in prose, not a bare slug" do
      assert {:error, reason} =
               NotifyPerson.run(
                 %{person: %{"email" => "no-id@example.com"}, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert reason =~ "person id"
      refute reason == "missing_person_id"
    end

    test "consumes the person payload returned by EnsurePerson" do
      assert {:ok, %{person: %{id: person_id} = person}} =
               EnsurePerson.run(
                 %{platform: "email", email: "handoff@example.com", display_name: "Handoff"},
                 %{}
               )

      assert {:ok, %{notified: true, status: :dispatched}} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.person_id == person_id
    end

    test "consumes a string-keyed person payload after JSONB round-trip" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :dispatched}} =
               NotifyPerson.run(
                 %{person: %{"id" => person.id}, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.person_id == person.id
    end
  end

  # As a workflow node (context carries :run_id) the action contributes its own
  # entry to the step's log trail via the `{:ok, result, logs: [...]}` 3-tuple
  # (see Zaq.Engine.Workflows.StepRunner). As a plain agent tool it must keep
  # returning a 2-tuple — Jido.Exec would reject the keyword tail as directives.
  describe "run/2 — action log trail (workflow node)" do
    test "success in a workflow context returns a person_notified log entry" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :dispatched}, logs: logs} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter, run_id: "run-1"}
               )

      assert [%{event: "person_notified"} = entry] = logs
      assert entry.person_id == person.id
      assert is_integer(entry.duration_ms)
    end

    test "returns a plain 2-tuple when invoked as an agent tool (no run_id)" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :dispatched}} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )
    end
  end

  defp person_fixture do
    {:ok, %Person{} = person} =
      People.create_person(%{
        full_name: "Notify Person",
        email: "notify-person@example.com",
        phone: "+15550123"
      })

    person
  end
end
