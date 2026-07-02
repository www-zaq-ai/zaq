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

    test "dispatches an empty request when no input is given" do
      assert {:ok, %{dispatched: %{}}} =
               DispatchEvent.run(%{event_name: "lead_identified"}, @ctx)

      assert_received {:dispatched, %Event{} = event}
      assert event.request == %{}
      assert event.name == "lead_identified"
    end

    test "treats nil input as an empty request" do
      assert {:ok, %{dispatched: %{}}} =
               DispatchEvent.run(%{input: nil, event_name: "lead_identified"}, @ctx)
    end

    test "dispatches a scalar input verbatim as the request" do
      assert {:ok, %{dispatched: "seeds ready"}} =
               DispatchEvent.run(
                 %{input: "seeds ready", event_name: "notify_channel", destination: "channels"},
                 @ctx
               )

      assert_received {:dispatched, %Event{} = event}
      assert event.request == "seeds ready"
      assert event.next_hop.destination == :channels
    end

    test "a scalar input bypasses the cascade merge" do
      ctx = Map.put(@ctx, :__cascade__, %{"step_a" => %{"foo" => 1}})

      assert {:ok, %{dispatched: "just this"}} =
               DispatchEvent.run(%{input: "just this", event_name: "notify_channel"}, ctx)
    end

    test "defaults the destination to :engine when not set" do
      assert {:ok, _} = DispatchEvent.run(%{event_name: "lead_identified"}, @ctx)

      assert_received {:dispatched, %Event{} = event}
      assert event.next_hop.destination == :engine
    end

    test "routes to an explicit destination role" do
      assert {:ok, _} =
               DispatchEvent.run(
                 %{event_name: "lead_identified", destination: "agent"},
                 @ctx
               )

      assert_received {:dispatched, %Event{} = event}
      assert event.next_hop.destination == :agent
    end

    test "accepts an atom destination" do
      assert {:ok, _} =
               DispatchEvent.run(
                 %{event_name: "lead_identified", destination: :channels},
                 @ctx
               )

      assert_received {:dispatched, %Event{} = event}
      assert event.next_hop.destination == :channels
    end

    test "rejects an unknown destination before dispatching" do
      assert {:error, reason} =
               DispatchEvent.run(
                 %{event_name: "lead_identified", destination: "mars"},
                 @ctx
               )

      assert reason =~ "unsupported destination"
      refute_received {:dispatched, _}
    end

    test "dispatches the merged outputs of prior steps from the cascade" do
      ctx =
        Map.put(@ctx, :__cascade__, %{
          "step_a" => %{"foo" => 1, :nested => %{"x" => true}},
          "step_b" => %{bar: 2}
        })

      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(%{event_name: "lead_identified"}, ctx)

      assert dispatched == %{"foo" => 1, "nested" => %{"x" => true}, "bar" => 2}
    end

    test "drops engine-internal plumbing keys from the cascade" do
      ctx =
        Map.put(@ctx, :__cascade__, %{
          "step_a" => %{"keep" => 1, :__cascade__ => %{}, "__map_index__" => 3}
        })

      assert {:ok, %{dispatched: %{"keep" => 1} = dispatched}} =
               DispatchEvent.run(%{event_name: "lead_identified"}, ctx)

      refute Map.has_key?(dispatched, "__cascade__")
      refute Map.has_key?(dispatched, "__map_index__")
    end

    test "explicit input is layered on top of prior outputs and wins on conflicts" do
      ctx = Map.put(@ctx, :__cascade__, %{"step_a" => %{"foo" => 1, "bar" => 2}})

      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(
                 %{input: %{"bar" => 99, "extra" => "added"}, event_name: "lead_identified"},
                 ctx
               )

      assert dispatched == %{"foo" => 1, "bar" => 99, "extra" => "added"}
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

    test "marks the request as a machine run when machine: true" do
      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified", machine: true},
                 @ctx
               )

      assert dispatched["machine"] == true

      assert_received {:dispatched, %Event{} = event}
      assert event.request["machine"] == true
    end

    test "omits the machine marker by default" do
      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
                 @ctx
               )

      refute Map.has_key?(dispatched, "machine")
    end

    test "omits the machine marker when machine: false" do
      assert {:ok, %{dispatched: dispatched}} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified", machine: false},
                 @ctx
               )

      refute Map.has_key?(dispatched, "machine")
    end

    test "dispatches any event name — there is no allowlist" do
      assert {:ok, %{dispatched: %{}}} =
               DispatchEvent.run(%{input: %{}, event_name: "any_event_name_works"}, @ctx)

      assert_received {:dispatched, %Event{} = event}
      assert event.name == "any_event_name_works"
    end

    test "rejects a blank event name" do
      assert {:error, reason} =
               DispatchEvent.run(%{input: %{}, event_name: "   "}, @ctx)

      assert reason =~ "must not be blank"
    end
  end

  # As a workflow node (context carries :run_id) the tool contributes its own
  # entry to the step's log trail via the `{:ok, result, logs: [...]}` 3-tuple
  # (see Zaq.Engine.Workflows.StepRunner). As a plain agent tool it must keep
  # returning a 2-tuple — Jido.Exec would reject the keyword tail as directives.
  describe "run/2 — action log trail (workflow node)" do
    @wf_ctx %{node_router: StubNodeRouter, run_id: "run-1"}

    test "success in a workflow context returns an event_dispatched log entry" do
      assert {:ok, %{dispatched: _}, logs: logs} =
               DispatchEvent.run(
                 %{input: %{"email" => "a@b.com"}, event_name: "lead_identified"},
                 @wf_ctx
               )

      assert [%{event: "event_dispatched"} = entry] = logs
      assert entry.event_name == "lead_identified"
      assert entry.destination == "engine"
      assert is_integer(entry.duration_ms)
    end

    test "async dispatch (no sync response) also returns the log entry" do
      ctx = %{node_router: AsyncNodeRouter, run_id: "run-1"}

      assert {:ok, _result, logs: [%{event: "event_dispatched"}]} =
               DispatchEvent.run(%{event_name: "lead_identified"}, ctx)
    end

    test "returns a plain 2-tuple when invoked as an agent tool (no run_id)" do
      assert {:ok, %{dispatched: _}} =
               DispatchEvent.run(%{event_name: "lead_identified"}, @ctx)
    end

    test "a failed dispatch names the event and destination in human-readable prose" do
      assert {:error, reason} =
               DispatchEvent.run(
                 %{input: %{}, event_name: "lead_identified"},
                 %{node_router: FailingNodeRouter, run_id: "run-1"}
               )

      assert reason =~ ~s(Dispatch of "lead_identified" to engine failed)
      assert reason =~ "something_went_wrong"
    end
  end

  describe "schema/0" do
    test "exposes input, event_name, destination and machine, but no raw hop controls" do
      keys = Keyword.keys(DispatchEvent.schema())

      assert :input in keys
      assert :event_name in keys
      assert :destination in keys
      assert :machine in keys
      # The raw event-struct name and hop type stay internal.
      refute :name in keys
      refute :type in keys
    end

    test "destination is optional and defaults to \"engine\"" do
      destination_opts = Keyword.fetch!(DispatchEvent.schema(), :destination)

      refute destination_opts[:required]
      assert destination_opts[:default] == "engine"
    end
  end
end
