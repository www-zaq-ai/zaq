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

  describe "run/2 — dispatch shape" do
    test "dispatches a :run_pipeline event to the agent node" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "say hi"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :agent
      assert event.opts[:action] == :run_pipeline
      assert event.request.content == "say hi"
      assert event.request.provider == nil
    end

    test "selects the configured agent by id via assigns.agent_selection" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.assigns["agent_selection"]["agent_id"] == agent.id
    end

    test "passes skip_permissions: true when the context grants it" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx(%{skip_permissions: true}))

      assert_received {:dispatched, event}
      assert event.opts[:pipeline_opts][:skip_permissions] == true
    end

    test "defaults skip_permissions to false when the context omits it" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.opts[:pipeline_opts][:skip_permissions] == false
    end

    test "carries the run_id as data on the incoming metadata in a workflow context" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.metadata[:run_id] == "test-run-1"
      # The tool never computes a scope string — that's derive_scope's job.
      assert event.request.metadata[:execution_scope] == nil
    end

    test "carries the step_index as data on the incoming metadata in a workflow context" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx(%{step_index: 3}))

      assert_received {:dispatched, event}
      assert event.request.metadata[:run_id] == "test-run-1"
      # step_index lets derive_scope/2 give each run_agent step its own server.
      assert event.request.metadata[:step_index] == 3
    end

    test "omits step_index from metadata when the context has no run_id" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "hello"},
        %{node_router: OkRouter, step_index: 3}
      )

      assert_received {:dispatched, event}
      # No run marker without a run_id, so no step marker either.
      assert event.request.metadata[:run_id] == nil
      assert event.request.metadata[:step_index] == nil
    end

    test "propagates the context actor onto the dispatched event" do
      agent = create_agent()
      actor = %{person: %{id: 99}}

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx(%{actor: actor}))

      assert_received {:dispatched, event}
      assert event.actor == actor
    end

    test "derives author_id from the context actor's person id (no hardcoded literal)" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx(%{actor: %{person: %{id: 99}}}))

      assert_received {:dispatched, event}
      assert event.request.author_id == "99"
    end

    test "leaves author_id nil when the context carries no actor/person" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.author_id == nil
    end

    test "tool-call context (parent incoming, no run_id) carries no run marker" do
      agent = create_agent()

      parent =
        %Zaq.Engine.Messages.Incoming{
          content: "parent question",
          channel_id: "c",
          provider: :web,
          person: %{id: 7}
        }

      ctx = %{node_router: OkRouter, incoming: parent, actor: %{person: %{id: 7}}}

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)

      assert_received {:dispatched, event}
      # No run_id → no marker; derive_scope falls to the standard person scope.
      # The child is a different agent name, so it cannot collide with the parent.
      assert event.request.metadata[:run_id] == nil
      assert event.request.provider == nil
    end

    test "carries no run marker when neither run_id nor incoming is present" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, %{node_router: OkRouter})

      assert_received {:dispatched, event}
      assert event.request.metadata[:run_id] == nil
    end

    test "sets channel_id to workflow:<run_id>" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.channel_id == "workflow:test-run-1"
    end

    test "uses anon when run_id is absent from context" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "hello"}, %{node_router: OkRouter})

      assert_received {:dispatched, event}
      assert event.request.channel_id == "workflow:anon"
    end

    test "accepts run_id from string context key" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "hello"},
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
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())
    end
  end

  describe "run/2 — failure" do
    test "returns error when the response Outgoing has metadata[:error]" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, FailingRouter)

      assert {:error, "agent_failed:llm_timeout"} =
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)
    end

    test "returns agent_failed:unknown when reason is missing" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, FailingNoReasonRouter)

      assert {:error, "agent_failed:unknown"} =
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)
    end

    test "returns agent_failed when the response is an error tuple" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, ErrorResponseRouter)

      assert {:error, "agent_failed:" <> _} =
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)
    end

    test "returns agent_failed when the response has an unexpected shape" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, UnexpectedResponseRouter)

      assert {:error, "agent_failed::not_an_outgoing_response"} =
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)
    end
  end

  describe "run/2 — template substitution" do
    test "substitutes {{variable}} in input from extra params" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "Draft for {{name}} at {{company}}",
          name: "Alice",
          company: "Acme"
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "Draft for Alice at Acme"
    end

    test "does not pass an agent job as a system_prompt override" do
      agent = create_agent(%{job: "You assist {{role}} teams at {{company}}."})

      RunAgent.run(
        %{agent_id: agent.id, input: "hello", role: "sales", company: "Globex"},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      refute Keyword.has_key?(event.opts[:pipeline_opts], :system_prompt)
    end

    test "leaves unmatched {{placeholders}} in input as empty string" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "Hello {{missing}}."}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.content == "Hello ."
    end

    test "handles integer extra params in substitution" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "Sequence {{seq}}", seq: 3}, ok_ctx())

      assert_received {:dispatched, event}
      assert event.request.content == "Sequence 3"
    end

    test "stringifies floats, booleans, nils and structured values in substitution" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
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

    test "does not pass agent_id or input as substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "{{agent_id}} and {{input}} should be empty."},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == " and  should be empty."
    end
  end

  # The substitution regex is ~r/\{\{(\w+)\}\}/, and \w is [A-Za-z0-9_] — it does
  # NOT include spaces. So a placeholder must use a single-token name like
  # `company_summary`; `{{company summary}}` (with a space) never matches and is
  # left verbatim in the prompt. This pins that contract.
  describe "run/2 — placeholder tokens cannot contain spaces" do
    test "{{company summary}} (with a space) is NOT substituted, even when the value is present" do
      agent = create_agent()

      RunAgent.run(
        %{
          # Value supplied under the spaced key — it must still NOT be injected.
          "company summary" => "Acme builds rockets.",
          agent_id: agent.id,
          input:
            "Based on the following company summary: {{company summary}}, write a concise list of the top services ZAQ can provide to this business and for each provide a clear benefit and a short explanation of how is it relevant."
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      # The spaced placeholder is left untouched (verbatim), not replaced.
      assert event.request.content =~ "{{company summary}}"
      refute event.request.content =~ "Acme builds rockets."
    end

    test "{{company_summary}} (underscore) IS substituted" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input:
            "Based on the following company summary: {{company_summary}}, write a concise list of the top services ZAQ can provide to this business and for each provide a clear benefit and a short explanation of how is it relevant.",
          company_summary: "Acme builds rockets."
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content =~ "company summary: Acme builds rockets., write"
      refute event.request.content =~ "{{"
    end
  end

  describe "run/2 — nested map (row) flattening" do
    test "flattens row map fields into substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
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
          agent_id: agent.id,
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
        %{agent_id: agent.id, input: "{{email}}", row: %{email: "lead@example.com"}},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.content == "lead@example.com"
    end

    test "excludes __cascade__ from substitution vars" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
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
          agent_id: agent.id,
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
