defmodule Zaq.Agent.Tools.Workflow.DispatchEventTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.DispatchEvent
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      %{event | response: {:ok, :accepted}}
    end
  end

  defmodule AsyncNodeRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:dispatched, event})
      event
    end
  end

  defmodule FailingNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:error, :something_went_wrong}}
    end
  end

  @ctx %{node_router: StubNodeRouter}

  describe "run/2" do
    test "dispatches an allowlisted event to the engine asynchronously" do
      input = %{"email" => "a@b.com"}

      assert {:ok, %{dispatched: %{"email" => "a@b.com"}}} =
               DispatchEvent.run(%{input: input, event_name: "lead_identified"}, @ctx)

      assert_received {:dispatched, %Event{} = event}
      assert event.next_hop.destination == :engine
      assert event.next_hop.type == :async
      assert event.name == "lead_identified"
    end

    test "stringifies atom-keyed input" do
      input = %{email: "a@b.com", active: true}

      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(%{input: input, event_name: "lead_identified"}, @ctx)

      assert Map.has_key?(dispatched, "email")
      assert Map.has_key?(dispatched, "active")
      refute Map.has_key?(dispatched, :email)
    end

    test "returns ok when async dispatch has no response" do
      assert {:ok, %{dispatched: %{"email" => "a@b.com"}}} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
                 %{node_router: AsyncNodeRouter}
               )
    end

    test "returns error when node_router response is {:error, reason}" do
      assert {:error, reason} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
                 %{node_router: FailingNodeRouter}
               )

      assert String.contains?(reason, "something_went_wrong")
    end

    test "rejects non-allowlisted event names" do
      assert {:error, reason} =
               DispatchEvent.run(%{input: %{}, event_name: "any_event_name_works"}, @ctx)

      assert reason =~ "unsupported event_name"
      assert reason =~ "lead_identified"
    end
  end

  describe "schema/0" do
    test "does not expose arbitrary destination or hop type controls" do
      keys = Keyword.keys(DispatchEvent.schema())

      assert :input in keys
      assert :event_name in keys
      refute :destination in keys
      refute :name in keys
      refute :type in keys
    end
  end
end
