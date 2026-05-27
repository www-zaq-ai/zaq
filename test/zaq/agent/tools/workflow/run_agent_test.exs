defmodule Zaq.Agent.Tools.Workflow.RunAgentTest do
  use Zaq.DataCase, async: true

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Tools.Workflow.RunAgent
  alias Zaq.Engine.Messages.Outgoing

  @ctx %{run_id: "test-run-1"}

  # ── Stub executors ─────────────────────────────────────────────────────────────

  defmodule OkExecutor do
    def run(incoming, _opts) do
      send(self(), {:executor_called, incoming})
      %Outgoing{body: "Hello from agent", channel_id: incoming.channel_id, provider: :workflow}
    end
  end

  defmodule SpyExecutor do
    def run(incoming, opts) do
      send(self(), {:executor_called, incoming, opts})
      %Outgoing{body: "spy response", channel_id: incoming.channel_id, provider: :workflow}
    end
  end

  defmodule FailingExecutor do
    def run(incoming, _opts) do
      %Outgoing{
        body: "",
        channel_id: incoming.channel_id,
        provider: :workflow,
        metadata: %{error: true, reason: "llm_timeout"}
      }
    end
  end

  defmodule FailingNoReasonExecutor do
    def run(incoming, _opts) do
      %Outgoing{
        body: "",
        channel_id: incoming.channel_id,
        provider: :workflow,
        metadata: %{error: true}
      }
    end
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

  # ── Tests ──────────────────────────────────────────────────────────────────────

  describe "run/2 — agent not found" do
    test "returns error when agent_name does not exist" do
      name = "Ghost_#{System.unique_integer([:positive])}"
      assert {:error, msg} = RunAgent.run(%{agent_name: name, input: "hello"}, @ctx)
      assert msg == "agent_not_found:#{name}"
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

    test "is case-sensitive" do
      agent = create_agent()
      upper_name = String.upcase(agent.name)

      if upper_name != agent.name do
        assert {:error, :agent_not_found} = Agent.get_agent_by_name(upper_name)
      end
    end
  end

  describe "variable substitution — agent lookup and template storage" do
    test "stores {{variable}} templates in job field without modification" do
      agent = create_agent(%{job: "You help {{role}} professionals at {{company}}."})
      assert {:ok, found} = Agent.get_agent_by_name(agent.name)
      assert found.job == "You help {{role}} professionals at {{company}}."
    end

    test "run/2 fails with agent_not_found before reaching executor" do
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

  describe "run/2 — successful execution" do
    test "returns {:ok, %{output: body}} from executor response" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      assert {:ok, %{output: "Hello from agent"}} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end

    test "calls executor with incoming message" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "say hi"}, ctx)

      assert_received {:executor_called, incoming}
      assert incoming.content == "say hi"
      assert incoming.provider == :workflow
    end

    test "sets channel_id to workflow:<run_id>" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, incoming}
      assert incoming.channel_id == "workflow:test-run-1"
    end

    test "uses anon when run_id is absent from context" do
      agent = create_agent()
      ctx = %{executor: OkExecutor}

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, incoming}
      assert incoming.channel_id == "workflow:anon"
    end

    test "accepts run_id from string context key" do
      agent = create_agent()
      ctx = %{"run_id" => "string-run-42", executor: OkExecutor}

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, incoming}
      assert incoming.channel_id == "workflow:string-run-42"
    end

    test "passes agent_id and skip_permissions to executor opts" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, _incoming, opts}
      assert opts[:agent_id] == agent.id
      assert opts[:skip_permissions] == true
    end

    test "passes scope with run_id to executor opts" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, _incoming, opts}
      assert opts[:scope] == "workflow:run:test-run-1"
    end
  end

  describe "run/2 — executor failure" do
    test "returns error when executor sets metadata[:error]" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, FailingExecutor)

      assert {:error, "agent_failed:llm_timeout"} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end

    test "returns agent_failed:unknown when reason is missing" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, FailingNoReasonExecutor)

      assert {:error, "agent_failed:unknown"} =
               RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)
    end
  end

  describe "run/2 — template substitution" do
    test "substitutes {{variable}} in input from extra params" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Draft for {{name}} at {{company}}",
          name: "Alice",
          company: "Acme"
        },
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "Draft for Alice at Acme"
    end

    test "substitutes {{variable}} in agent job (system_prompt)" do
      agent = create_agent(%{job: "You assist {{role}} teams at {{company}}."})
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(
        %{agent_name: agent.name, input: "hello", role: "sales", company: "Globex"},
        ctx
      )

      assert_received {:executor_called, _incoming, opts}
      assert opts[:system_prompt] == "You assist sales teams at Globex."
    end

    test "leaves unmatched {{placeholders}} as empty string" do
      agent = create_agent(%{job: "Hello {{missing}}."})
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hi"}, ctx)

      assert_received {:executor_called, _incoming, opts}
      assert opts[:system_prompt] == "Hello ."
    end

    test "handles integer extra params in substitution" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{agent_name: agent.name, input: "Sequence {{seq}}", seq: 3},
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "Sequence 3"
    end

    test "does not pass agent_name or input as substitution vars" do
      agent = create_agent(%{job: "{{agent_name}} and {{input}} should be empty."})
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, _incoming, opts}
      # agent_name and input are excluded from vars — placeholders become ""
      assert opts[:system_prompt] == " and  should be empty."
    end

    test "handles empty string job as empty system_prompt" do
      # DB requires job to be non-blank, so the nil guard in `agent.job || ""`
      # is defensive — test with the closest valid case: an explicit empty
      # string is prevented by the schema, so we use a blank-ish job string
      # and verify it flows through unchanged.
      agent = create_agent(%{job: "{{only_placeholder}}"})
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(%{agent_name: agent.name, input: "hello"}, ctx)

      assert_received {:executor_called, _incoming, opts}
      # no vars provided → placeholder resolves to ""
      assert opts[:system_prompt] == ""
    end
  end

  describe "run/2 — nested map (row) flattening" do
    test "flattens row map fields into substitution vars" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Draft for {{name}} at {{company}}, position: {{position}}",
          row: %{"name" => "John Doe", "company" => "Acme", "position" => "CTO"}
        },
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "Draft for John Doe at Acme, position: CTO"
    end

    test "flat top-level params win over same-key nested map values" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "Hello {{name}}",
          name: "FlatAlice",
          row: %{"name" => "NestedBob"}
        },
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "Hello FlatAlice"
    end

    test "atom-keyed row fields are also flattened" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "{{email}}",
          row: %{email: "lead@example.com"}
        },
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "lead@example.com"
    end

    test "excludes __cascade__ from substitution vars" do
      agent = create_agent(%{job: "{{__cascade__}} check"})
      ctx = Map.put(@ctx, :executor, SpyExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "hello",
          __cascade__: %{some_step: %{result: "data"}}
        },
        ctx
      )

      assert_received {:executor_called, _incoming, opts}
      assert opts[:system_prompt] == " check"
    end

    test "multiple nested maps are all flattened" do
      agent = create_agent()
      ctx = Map.put(@ctx, :executor, OkExecutor)

      RunAgent.run(
        %{
          agent_name: agent.name,
          input: "{{name}} — {{city}}",
          row: %{"name" => "Jane"},
          extra: %{"city" => "Beirut"}
        },
        ctx
      )

      assert_received {:executor_called, incoming}
      assert incoming.content == "Jane — Beirut"
    end
  end
end
