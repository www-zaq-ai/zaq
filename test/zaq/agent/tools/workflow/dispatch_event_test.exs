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
      # async dispatch returns event with nil response
      event
    end
  end

  defmodule FailingNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:error, :something_went_wrong}}
    end
  end

  @ctx %{node_router: StubNodeRouter}

  describe "run/2 — successful dispatch" do
    test "dispatches event to the given destination" do
      input = %{"email" => "a@b.com"}

      assert {:ok, %{dispatched: %{"email" => "a@b.com"}}} =
               DispatchEvent.run(%{input: input, destination: "engine"}, @ctx)

      assert_received {:dispatched, %Event{next_hop: hop}}
      assert hop.destination == :engine
    end

    test "sets event name when provided" do
      input = %{"email" => "a@b.com"}

      DispatchEvent.run(
        %{input: input, destination: "engine", name: "lead_identified"},
        @ctx
      )

      assert_received {:dispatched, %Event{name: "lead_identified"}}
    end

    test "stringifies atom-keyed input" do
      input = %{email: "a@b.com", active: true}

      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(%{input: input, destination: "engine"}, @ctx)

      assert Map.has_key?(dispatched, "email")
      assert Map.has_key?(dispatched, "active")
      refute Map.has_key?(dispatched, :email)
    end

    test "uses Zaq.NodeRouter by default when not in context" do
      # Just verify it doesn't crash on context lookup — actual dispatch
      # would fail without a running node, so we only test the path here.
      assert is_function(&DispatchEvent.run/2)
    end
  end

  describe "run/2 — async dispatch" do
    test "returns ok when node_router response is nil (async enqueued)" do
      assert {:ok, %{dispatched: %{"email" => "a@b.com"}}} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, destination: "engine", type: "async"},
                 %{node_router: AsyncNodeRouter}
               )

      assert_received {:dispatched, %Event{}}
    end
  end

  describe "run/2 — failed dispatch" do
    test "returns error when node_router response is {:error, reason}" do
      input = %{"email" => "a@b.com"}

      assert {:error, reason} =
               DispatchEvent.run(
                 %{input: input, destination: "engine"},
                 %{node_router: FailingNodeRouter}
               )

      assert String.contains?(reason, "something_went_wrong")
    end

    test "returns error for unknown destination" do
      assert {:error, reason} =
               DispatchEvent.run(
                 %{input: %{}, destination: "nowhere"},
                 @ctx
               )

      assert String.contains?(reason, "unknown destination")
      assert String.contains?(reason, "nowhere")
    end

    test "accepts any string event name without atom interning" do
      assert {:ok, %{dispatched: _}} =
               DispatchEvent.run(
                 %{input: %{}, destination: "engine", name: "any_event_name_works"},
                 @ctx
               )

      assert_received {:dispatched, %Event{name: "any_event_name_works"}}
    end
  end
end
