defmodule Zaq.Agent.Tools.Workflow.RunAgentTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Context, as: AIContext
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

  defmodule TraceRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      %{
        event
        | response: %Outgoing{
            body: "Hello from agent",
            channel_id: event.request.channel_id,
            provider: nil,
            metadata: %{
              trace: [%{"id" => "llm:0:content", "type" => "content"}],
              agent: %{id: 1, name: "Bot"},
              model: "gpt-4",
              measurements: %{"latency_ms" => 10}
            }
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

  # RunAgent builds the seed turns into a `Jido.AI.Context` carried on the event's
  # `pipeline_opts[:context]` (nil when none). These read it back as messages
  # (atom roles, chronological) for assertions.
  defp seeded_context(event), do: event.opts[:pipeline_opts][:context]

  defp seeded_messages(event) do
    case seeded_context(event) do
      %AIContext{} = ctx -> AIContext.to_messages(ctx)
      other -> other
    end
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

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

    test "accepts fully string-keyed params without crashing (atomize_keys fallback shape)" do
      # When a workflow node carries a param key with no existing atom, the DAG
      # builder leaves the whole param map string-keyed. run/2 must still resolve
      # agent_id/input from that shape.
      agent = create_agent()

      RunAgent.run(
        %{"agent_id" => agent.id, "input" => "hello world"},
        %{node_router: OkRouter}
      )

      assert_received {:dispatched, event}
      assert event.request.content == "hello world"
      assert event.assigns["agent_selection"]["agent_id"] == agent.id
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

    test "returns safe defaults for trace/agent/model/measurements when metadata is empty" do
      agent = create_agent()

      assert {:ok,
              %{output: "Hello from agent", trace: [], agent: nil, model: nil, measurements: %{}}} =
               RunAgent.run(%{agent_id: agent.id, input: "hello"}, ok_ctx())
    end

    test "carries trace/agent/model/measurements through from outgoing.metadata" do
      agent = create_agent()
      ctx = Map.put(@ctx, :node_router, TraceRouter)

      assert {:ok, result} = RunAgent.run(%{agent_id: agent.id, input: "hello"}, ctx)

      assert result.output == "Hello from agent"
      assert result.trace == [%{"id" => "llm:0:content", "type" => "content"}]
      assert result.agent == %{"id" => 1, "name" => "Bot"}
      assert result.model == "gpt-4"
      assert result.measurements == %{"latency_ms" => 10}
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

  # Substitution runs through `Zaq.Engine.Workflows.Placeholders`, whose key class
  # allows spaces and hyphens — human-authored sheet headers ("Company Context
  # Content") are real keys. This used to be RunAgent's own `~r/\{\{(\w+)\}\}/`,
  # which silently left a spaced placeholder verbatim in the prompt while the same
  # key substituted fine in `Concat` and `DispatchEvent`.
  # Sharing `Placeholders` with `Concat` and `DispatchEvent` gives a RunAgent prompt
  # the same reach they have. Previously `build_vars/1` was the only source, so a
  # placeholder could name nothing beyond the node's own params.
  describe "run/2 — context (seeded AIContext)" do
    test "builds normalised context turns into the seeded AIContext, order preserved" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "continue",
          context: [
            %{role: "user", content: "first"},
            %{role: "assistant", content: "second"},
            %{role: "tool", content: "third"}
          ]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [
               %{role: :user, content: "first"},
               %{role: :assistant, content: "second"},
               %{role: :tool, content: "third"}
             ] = seeded_messages(event)
    end

    test "preserves tool_calls on an assistant turn" do
      agent = create_agent()
      tool_calls = [%{"id" => "call_1", "name" => "search"}]

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [%{role: "assistant", content: "calling", tool_calls: tool_calls}]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [turn] = seeded_messages(event)
      assert turn.role == :assistant
      assert turn.tool_calls == tool_calls
    end

    test "preserves tool_call_id and name on a tool turn" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [%{role: "tool", content: "42", tool_call_id: "call_1", name: "search"}]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [turn] = seeded_messages(event)
      assert turn.role == :tool
      assert turn.content == "42"
      assert turn.tool_call_id == "call_1"
      assert turn.name == "search"
    end

    test "accepts string-keyed context entries (JSONB round-trip shape)" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [%{"role" => "user", "content" => "hello"}]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [%{role: :user, content: "hello"}] = seeded_messages(event)
    end

    test "accepts an atom-valued role" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "go", context: [%{role: :user, content: "hi"}]},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [%{role: :user, content: "hi"}] = seeded_messages(event)
    end

    test "drops entries with an unknown role but still dispatches the run" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [
            %{role: "user", content: "keep me"},
            %{role: "system", content: "drop me"},
            %{role: "nonsense", content: "also drop"}
          ]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [%{role: :user, content: "keep me"}] = seeded_messages(event)
    end

    test "drops non-map context entries" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [%{role: "user", content: "ok"}, "not a map", 42]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [%{content: "ok"}] = seeded_messages(event)
    end

    test "sends no :context in pipeline_opts when context is an empty list" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "go", context: []}, ok_ctx())

      assert_received {:dispatched, event}
      assert seeded_context(event) == nil
    end

    test "sends no :context in pipeline_opts when context is absent" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "go"}, ok_ctx())

      assert_received {:dispatched, event}
      assert seeded_context(event) == nil
    end

    test "stringifies non-string content in a context turn" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [
            %{role: "tool", content: 42},
            %{role: "user", content: %{"nested" => "value"}}
          ]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [
               %{role: :tool, content: "42"},
               %{role: :user, content: content}
             ] = seeded_messages(event)

      assert content =~ "nested"
    end

    test "omits optional turn fields the round-trip does not carry when absent" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [
            %{role: "assistant", content: "no tools"},
            %{role: "tool", content: "result only"}
          ]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [assistant_turn, tool_turn] = seeded_messages(event)
      assert assistant_turn == %{role: :assistant, content: "no tools"}
      assert tool_turn == %{role: :tool, content: "result only", tool_call_id: nil, name: nil}
    end

    test "wraps a single context map into a one-element seeded context" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "go", context: %{role: "user", content: "solo"}},
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [%{role: :user, content: "solo"}] = seeded_messages(event)
    end

    test "keeps a turn whose content is missing or empty as an empty string" do
      # Carrier is a mechanical normaliser: it does not drop empty turns — deciding
      # what to do with an empty message is the consumer's job (Issue 2).
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [
            %{role: "user"},
            %{role: "tool", content: ""}
          ]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}

      assert [
               %{role: :user, content: ""},
               %{role: :tool, content: ""}
             ] = seeded_messages(event)
    end
  end

  describe "run/2 — context_max_size" do
    test "carries a positive integer context_max_size on the incoming metadata" do
      agent = create_agent()

      RunAgent.run(
        %{agent_id: agent.id, input: "go", context_max_size: 2000},
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert event.request.metadata[:context_max_size] == 2000
    end

    test "parses a numeric string context_max_size (JSONB / tool-arg shape)" do
      agent = create_agent()

      RunAgent.run(
        %{"agent_id" => agent.id, "input" => "go", "context_max_size" => "1500"},
        %{node_router: OkRouter}
      )

      assert_received {:dispatched, event}
      assert event.request.metadata[:context_max_size] == 1500
    end

    test "omits context_max_size when absent" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "go"}, ok_ctx())

      assert_received {:dispatched, event}
      refute Map.has_key?(event.request.metadata, :context_max_size)
    end

    test "ignores a non-positive context_max_size" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "go", context_max_size: 0}, ok_ctx())

      assert_received {:dispatched, event}
      refute Map.has_key?(event.request.metadata, :context_max_size)
    end

    test "ignores an unparseable context_max_size" do
      agent = create_agent()

      RunAgent.run(%{agent_id: agent.id, input: "go", context_max_size: "lots"}, ok_ctx())

      assert_received {:dispatched, event}
      refute Map.has_key?(event.request.metadata, :context_max_size)
    end

    # Each turn below is ~10 words ≈ 13 tokens (TokenEstimator: words × 1.3, ceil).
    # A budget of 20 fits only the newest turn (13 ok; +13 = 26 > 20 halts), proving
    # the seed context is trimmed here rather than passed through unbounded.
    test "trims the oldest seed turns that overflow context_max_size, keeping the newest" do
      agent = create_agent()
      turn = fn label -> %{role: "user", content: label <> " " <> String.duplicate("w ", 9)} end

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [turn.("oldest"), turn.("middle"), turn.("newest")],
          context_max_size: 20
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [only] = seeded_messages(event)
      assert only.role == :user
      assert only.content =~ "newest"
    end

    test "keeps every seed turn when the default budget is not exceeded" do
      agent = create_agent()

      RunAgent.run(
        %{
          agent_id: agent.id,
          input: "go",
          context: [%{role: "user", content: "a"}, %{role: "assistant", content: "b"}]
        },
        ok_ctx()
      )

      assert_received {:dispatched, event}
      assert [%{content: "a"}, %{content: "b"}] = seeded_messages(event)
    end
  end

  describe "run/2 — context messages (property)" do
    @valid_roles ["user", "assistant", "tool"]

    property "any list of valid entries round-trips to the same ordered role sequence" do
      agent = create_agent()

      check all(
              roles <- StreamData.list_of(StreamData.member_of(@valid_roles), max_length: 10),
              string_keys? <- StreamData.boolean()
            ) do
        entries =
          Enum.map(roles, fn role ->
            entry = %{role: role, content: "content-#{role}"}
            if string_keys?, do: stringify_keys(entry), else: entry
          end)

        RunAgent.run(%{agent_id: agent.id, input: "go", context: entries}, ok_ctx())

        assert_received {:dispatched, event}
        messages = seeded_messages(event) || []
        assert Enum.map(messages, &to_string(&1.role)) == roles
      end
    end

    @invalid_roles ["system", "developer", "bogus", ""]

    property "invalid-role entries are dropped while valid ones keep their order" do
      agent = create_agent()

      check all(
              specs <-
                StreamData.list_of(
                  StreamData.tuple(
                    {StreamData.member_of(@valid_roles ++ @invalid_roles),
                     StreamData.string(:alphanumeric, min_length: 1, max_length: 6)}
                  ),
                  max_length: 12
                )
            ) do
        entries = Enum.map(specs, fn {role, content} -> %{role: role, content: content} end)

        RunAgent.run(%{agent_id: agent.id, input: "go", context: entries}, ok_ctx())

        assert_received {:dispatched, event}
        got = seeded_messages(event) || []

        expected_roles =
          specs |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 in @valid_roles))

        assert Enum.map(got, &to_string(&1.role)) == expected_roles
      end
    end
  end
end
