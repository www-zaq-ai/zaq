defmodule Zaq.Agent.Tools.People.NotifyPersonTest do
  use Zaq.DataCase, async: true

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

  describe "schema/0" do
    test "does not expose channel or sheet-specific fields" do
      keys = Keyword.keys(NotifyPerson.schema())

      assert :person_id in keys
      assert :subject in keys
      assert :message in keys
      refute :medium in keys
      refute :row_index in keys
      refute :email_state in keys
      refute :email_state_column in keys
    end
  end

  describe "run/2" do
    test "dispatches a notify_person event to the engine" do
      assert {:ok, %{notified: true, status: :dispatched}} =
               NotifyPerson.run(
                 %{person_id: 123, subject: "Hello", message: "Body"},
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :notify_person
      assert event.request == %{person_id: 123, subject: "Hello", message: "Body"}
    end

    test "treats skipped notifications as successful no-op dispatches" do
      assert {:ok, %{notified: true, status: :skipped}} =
               NotifyPerson.run(
                 %{person_id: 123, subject: "Hello", message: "Body"},
                 %{node_router: SkippedRouter}
               )
    end

    test "returns engine notification errors" do
      assert {:error, "person_not_found:123"} =
               NotifyPerson.run(
                 %{person_id: 123, subject: "Hello", message: "Body"},
                 %{node_router: ErrorRouter}
               )
    end
  end
end
