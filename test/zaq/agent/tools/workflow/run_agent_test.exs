defmodule Zaq.Agent.Tools.Workflow.RunAgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Tools.Workflow.RunAgent

  @ctx %{run_id: "test-run-1"}

  # ── Stub node routers ──────────────────────────────────────────────────────────
  #
  # RunAgent now dispatches a `:run_pipeline` event to the agent node via
  # NodeRouter instead of calling Executor directly. These stubs capture the
  # dispatched event and return a response on it, mirroring NodeRouter.dispatch/1.

  defmodule OkRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      send(self(), {:dispatched, event})

      %{
        event
        | response: %Outgoing{
            body: "Hello from agent",
            channel_id: event.request.channel_id,
            provider: nil
          }
      }
    end
  end

  defmodule FailingRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      %{
        event
        | response: %Outgoing{
            body: "",
            channel_id: event.request.channel_id,
            provider: nil,
            metadata: %{error: true, reason: "llm_timeout"}
          }
      }
    end
  end

  defmodule FailingNoReasonRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      %{
        event
        | response: %Outgoing{
            body: "",
            channel_id: event.request.channel_id,
            provider: nil,
            metadata: %{error: true}
          }
      }
    end
  end

  defmodule ErrorResponseRouter do
    def dispatch(event), do: %{event | response: {:error, :boom}}
  end

  defmodule UnexpectedResponseRouter do
    def dispatch(event), do: %{event | response: :not_an_outgoing_response}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────────

  defp create_agent(attrs \\ %{}) do
    credential =
      ai_credential_fixture(%{provider: "openai", endpoint: "https://api.openai.com/v1"})

    defaults = %{
      name: "TestAgent_#{System.unique_integer([:positive])}",
      job: "You are a helpful assistant.",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      strategy: "react",
      active: true
    }

    {:ok, agent} = Agent.create_agent(Map.merge(defaults, attrs))
    agent
  end

  defp ok_ctx(extra \\ %{}), do: @ctx |> Map.put(:node_router, OkRouter) |> Map.merge(extra)

  # ── Tests ──────────────────────────────────────────────────────────────────────

  describe "run/2 — agent not found" do
    test "returns error when agent_name does not exist" do
      name = "Ghost_#{System.unique_integer([:positive])}"
      assert {:error, msg} = RunAgent.run(%{agent_name: name, input: "hello"}, @ctx)
      assert msg == "agent_not_found:#{name}"
    end

    test "fails with agent_not_found before dispatching" do
      result =
        RunAgent.run(
          %{
            agent_name: "Missing_#{System.unique_integer([:positive])}",
            input: "Draft for {{name}}",
            name: "Alice",
            company: "Acme"
          },
          @ctx
        )

      assert {:error, "agent_not_found:" <> _} = result
    end
  end

  describe "get_agent_by_name/1" do
    test "returns agent when name matches" do
      agent = create_agent()
      assert {:ok, found} = Agent.get_agent_by_name(agent.name)
      assert found.id == agent.id
    end

    test "returns the correct job field" do
      agent = create_agent(%{job: "You help engineers."})
      assert {:ok, found} = Agent.get_agent_by_name(agent.name)
      assert found.job == "You help engineers."
    end

    test "returns error for unknown name" do
      assert {:error, :agent_not_found} =
               Agent.get_agent_by_name("NoSuchAgent_#{System.unique_integer([:positive])}")
    end
  end

  describe "run/2 — dispatch shape" do
    test "dispatches a :run_pipeline event to the agent node" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "say hi"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :agent
      assert event.opts[:action] == :run_pipeline
      assert event.request.content == "say hi"
      assert event.request.provider == nil
    end

    test "selects the resolved agent via assigns.agent_selection" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.assigns.agent_selection.agent_id == agent.id
    end

    test "requests skip_permissions in pipeline_opts" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.opts[:pipeline_opts][:skip_permissions] == true
    end

    test "sets channel_id to workflow:<run_id>" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.channel_id == "workflow:test-run-1"
    end

    test "uses anon when run_id is absent from context" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, %{node_router: OkRouter})

      assert_received {:dispatched, event}
      assert event.request.channel_id == "workflow:anon"
    end

    test "accepts run_id from string context key" do
      agent = create_agent()

      RunAgent.run(
        %{agent_name: agent.name, input: "hello"},
        %{"run_id" => "string-run-42", node_router: OkRouter}
      )

      assert_received {:dispatched, event}
      assert event.request.channel_id == "workflow:string-run-42"
    end
  end

  describe "run/2 — successful execution" do
    test "returns {:ok, %{output: body}} from the dispatch response" do
      agent = create_agent()

      assert {:ok, %{output: "Hello from agent"}} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ok_ctx())
    end
  end

  describe "run/2 — failure" do
    test "returns error when the response Outgoing has metadata[:error]" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, FailingRouter)

      assert {:error, "agent_failed:llm_timeout"} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end

    test "returns agent_failed:unknown when reason is missing" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, FailingNoReasonRouter)

      assert {:error, "agent_failed:unknown"} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end

    test "returns agent_failed when the response is an error tuple" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, ErrorResponseRouter)

      assert {:error, "agent_failed:" <> _} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end

    test "returns agent_failed when the response has an unexpected shape" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, UnexpectedResponseRouter)

      assert {:error, "agent_failed::not_an_outgoing_response"} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end
  end

  describe "run/2 — template substitution" do
    test "substitutes {{variable}} in input from extra params" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Draft for {{name}} at {{company}}",
          name: "Alice",
          company: "Acme"
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "Draft for Alice at Acme"
    end

    test "passes agent job through verbatim as system_prompt (no substitution)" do
      agent = create_agent(%{job: "You assist {{role}} teams at {{company}}."})

      RunAgent.run(
        %{agent_name: agent.name, input: "hello", role: "sales", company: "Globex"},
        ok_ctx()
      )

      assert_received {:dispatched, event}

      # The system prompt is kept static (cacheable) — placeholders are left as-is.
      assert event.opts[:pipeline_opts][:system_prompt] ==
               "You assist {{role}} teams at {{company}}."
    end

    test "leaves unmatched {{placeholders}} in input as empty string" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "Hello {{missing}}."}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.content == "Hello ."
    end

    test "handles integer extra params in substitution" do
      agent = create_agent()

      RunAgent.run(%{agent_name: agent.name, input: "Sequence {{seq}}", seq: 3}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.content == "Sequence 3"
    end

    test "stringifies floats, booleans, nils and structured values in substitution" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "{{score}} {{enabled}} {{missing_value}} {{payload}}",
          score: 1.5,
          enabled: false,
          missing_value: nil,
          payload: [:a, 1]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "1.5 false  [:a, 1]"
    end

    test "does not pass agent_name or input as substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{agent_name: agent.name, input: "{{agent_name}} and {{input}} should be empty."},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == " and  should be empty."
    end
  end

  describe "run/2 — nested map (row) flattening" do
    test "flattens row map fields into substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Draft for {{name}} at {{company}}, position: {{position}}",
          row: %{"name" => "John Doe", "company" => "Acme", "position" => "CTO"}
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "Draft for John Doe at Acme, position: CTO"
    end

    test "flat top-level params win over same-key nested map values" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Hello {{name}}",
          name: "FlatAlice",
          row: %{"name" => "NestedBob"}
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "Hello FlatAlice"
    end

    test "atom-keyed row fields are also flattened" do
      agent = create_agent()

      RunAgent.run(
        %{agent_name: agent.name, input: "{{email}}", row: %{email: "lead@example.com"}},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "lead@example.com"
    end

    test "excludes __cascade__ from substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "{{__cascade__}} check",
          __cascade__: %{some_step: %{result: "data"}}
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == " check"
    end

    test "multiple nested maps are all flattened" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "{{name}} — {{city}}",
          row: %{"name" => "Jane"},
          extra: %{"city" => "Beirut"}
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "Jane — Beirut"
    end
  end
end
