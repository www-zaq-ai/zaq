defmodule Zaq.Agent.Tools.People.NotifyPersonTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Mox
  setup :verify_on_exit!

  alias Jido.Action.Schema
  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Tools.People.EnsurePerson
  alias Zaq.Agent.Tools.People.NotifyPerson

  defmodule OkRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})

      %{
        event
        | response:
            {:ok,
             %{
               status: :sent,
               channel: "email:smtp",
               channel_identifier: "person@example.com",
               notification_log_id: 123
             }}
      }
    end
  end

  defmodule SkippedRouter do
    def dispatch(event),
      do: %{event | response: {:ok, %{status: :skipped, notification_log_id: 456}}}
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
      keys = Schema.known_keys(NotifyPerson.schema())

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

  describe "Jido execution" do
    test "parameter confidentiality cannot change trusted defaults" do
      assert {:ok, _} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{
                   person: %{id: 123},
                   subject: "Hello",
                   message: "Body",
                   confidential: true,
                   event_opts: [confidential: true]
                 },
                 %{node_router: OkRouter},
                 timeout: 0
               )

      assert_received {:dispatched, event}
      refute event.opts[:confidential]
    end

    test "confidential returned failures retain safe classification before Jido logs" do
      for reason <- [
            "private-error-body",
            %RuntimeError{message: "private-error-body"},
            {:provider_failed, "private-error-body"},
            {:ok, :unexpected}
          ] do
        expect(Zaq.NodeRouterMock, :dispatch, fn event ->
          response = if reason == {:ok, :unexpected}, do: reason, else: {:error, reason}
          %{event | response: response}
        end)

        log =
          ExUnit.CaptureLog.capture_log(
            [level: :warning, metadata: [:phase, :exception_type]],
            fn ->
              assert {:error, %Jido.Action.Error.ExecutionFailureError{details: details} = error} =
                       Jido.Exec.run(
                         NotifyPerson,
                         %{person: %{id: 123}, subject: "Hello", message: "private-message"},
                         %{node_router: Zaq.NodeRouterMock, event_opts: [confidential: true]},
                         timeout: 0
                       )

              assert details.phase == :delivery
              assert details.retry == false
              refute inspect(error) =~ "private-"
            end
          )

        assert log =~ "phase=delivery"
        if is_exception(reason), do: assert(log =~ "RuntimeError")
        refute log =~ "private-"
      end
    end

    test "ordinary raised and thrown failures retain Jido execution handling" do
      expect(Zaq.NodeRouterMock, :dispatch, fn _ -> raise "ordinary failure" end)

      assert {:error,
              %Jido.Action.Error.ExecutionFailureError{
                details: %{original_exception: %RuntimeError{}}
              }} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{person: %{id: 123}, subject: "Hello", message: "Body"},
                 %{node_router: Zaq.NodeRouterMock},
                 timeout: 0,
                 max_retries: 0
               )

      expect(Zaq.NodeRouterMock, :dispatch, fn _ -> throw(:ordinary_failure) end)

      assert {:error, %Jido.Action.Error.InternalError{}} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{person: %{id: 123}, subject: "Hello", message: "Body"},
                 %{node_router: Zaq.NodeRouterMock},
                 timeout: 0,
                 max_retries: 0
               )
    end

    property "only trusted confidentiality is forwarded and cannot override the action" do
      check all(message <- string(:alphanumeric, min_length: 1), max_runs: 10) do
        parent = self()

        Mox.expect(Zaq.NodeRouterMock, :dispatch, fn event ->
          send(parent, {:action_event, event})
          %{event | response: {:ok, %{status: :skipped}}}
        end)

        assert {:ok, %{notified: false, status: :skipped, content: ^message}} =
                 Jido.Exec.run(
                   NotifyPerson,
                   %{person: %{id: 123}, subject: "Hello", message: message},
                   %{
                     node_router: Zaq.NodeRouterMock,
                     event_opts: [confidential: true, action: :invoke, secret: message]
                   },
                   timeout: 0
                 )

        assert_received {:action_event, event}
        assert event.opts[:action] == :notify_person
        assert event.opts[:confidential] == true
        refute Keyword.has_key?(event.opts, :secret)
      end
    end

    test "malformed parameters fail Jido validation before dispatch" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{person: :invalid, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      refute_received {:dispatched, _}
    end

    test "ordinary execution retains sent payload and error contracts" do
      assert {:ok, %{notified: true, status: :sent, message: "Body", content: "Body"}} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{person: %{id: 123}, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter},
                 timeout: 0
               )

      assert_received {:dispatched, event}
      refute event.opts[:confidential]

      assert {:error, %Jido.Action.Error.ExecutionFailureError{message: "person_not_found:123"}} =
               Jido.Exec.run(
                 NotifyPerson,
                 %{person: %{id: 123}, subject: "Hello", message: "Body"},
                 %{node_router: ErrorRouter},
                 timeout: 0
               )
    end
  end

  describe "run/2" do
    test "dispatches a notify_person event to the engine" do
      person = person_fixture()

      assert {:ok,
              %{
                notified: true,
                status: :sent,
                channel: "email:smtp",
                channel_identifier: "person@example.com",
                provider: "email:smtp",
                channel_id: "person@example.com",
                author_id: "person@example.com",
                person: %{id: person_id},
                person_id: person_id,
                subject: "Hello",
                message: "Body",
                content: "Body",
                notification_log_id: 123
              }} =
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

      assert {:ok, %{notified: false, status: :skipped, notification_log_id: 456}} =
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

    test "returns a tagged failure when the engine response is unexpected" do
      person = person_fixture()

      assert {:error, "notify_person_failed:{:ok, :queued}"} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: UnexpectedRouter}
               )
    end

    test "consumes the person payload returned by EnsurePerson" do
      assert {:ok, %{person: %{id: person_id} = person}} =
               EnsurePerson.run(
                 %{platform: "email", email: "handoff@example.com", display_name: "Handoff"},
                 %{}
               )

      assert {:ok, %{notified: true, status: :sent}} =
               NotifyPerson.run(
                 %{person: person, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.person_id == person_id
    end

    test "consumes a string-keyed person payload after JSONB round-trip" do
      person = person_fixture()

      assert {:ok, %{notified: true, status: :sent}} =
               NotifyPerson.run(
                 %{person: %{"id" => person.id}, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.request.person_id == person.id
    end

    test "rejects person payloads without an integer id" do
      assert {:error, "missing_person_id"} =
               NotifyPerson.run(
                 %{person: %{id: "123"}, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert {:error, "missing_person_id"} =
               NotifyPerson.run(
                 %{person: :missing, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      refute_received {:dispatched, _event}
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
