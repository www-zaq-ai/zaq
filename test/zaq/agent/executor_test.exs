defmodule Zaq.Agent.ExecutorTest do
  use ExUnit.Case, async: true

  doctest Zaq.Agent.Executor

  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
    def get_active_agent_by_name(_agent_name), do: {:ok, %{id: 88, name: "Named Stub Agent"}}
  end

  defmodule MissingNamedStubAgent do
    def get_active_agent_by_name(_agent_name), do: {:error, :agent_not_found}
  end

  defmodule StubServerManager do
    def ensure_server(configured_agent, server_id) do
      send(self(), {:ensure_server, configured_agent, server_id})
      {:ok, :stub_server_scoped}
    end
  end

  defmodule StubFactory do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []),
      do: {:ok, %{request: :request, events: [completed_event("stubbed answer")]}}

    def answering_configured_agent, do: %{id: :answering, name: "answering"}

    defp completed_event(result, usage \\ %{}) do
      %{kind: :request_completed, at_ms: 10, data: %{result: result, usage: usage}}
    end
  end

  defmodule CoverageStubAgent do
    def get_active_agent(_agent_id),
      do: {:ok, %{id: 77, name: "Stub Agent", job: "Configured job"}}

    def get_active_agent_by_name(_agent_name),
      do: {:ok, %{id: 88, name: "Named Stub Agent", job: "Configured job"}}
  end

  defmodule CoverageStubServerManager do
    def ensure_server(configured_agent, server_id) do
      send(self(), {:coverage_ensure_server, configured_agent, server_id})
      {:ok, :coverage_stub_server}
    end
  end

  defmodule CoverageStubFactory do
    def ask_with_config(_server, content, configured_agent, opts \\ []) do
      send(self(), {
        :coverage_ask,
        content,
        configured_agent,
        Keyword.get(opts, :tool_context)
      })

      case Process.get(:coverage_await_result, {:ok, %{result: "stubbed answer"}}) do
        {:ok, response} ->
          {:ok, %{request: :coverage_request, events: [completed_event(response)]}}

        {:error, reason} ->
          {:ok, %{request: :coverage_request, events: [failed_event(reason)]}}
      end
    end

    def answering_configured_agent,
      do: %{id: :answering, name: "answering", job: "Configured job"}

    defp completed_event(%{result: result, usage: usage}) do
      %{kind: :request_completed, at_ms: 10, data: %{result: result, usage: usage}}
    end

    defp completed_event(%{"result" => %{"usage" => usage}} = result) do
      %{kind: :request_completed, at_ms: 10, data: %{result: result, usage: usage}}
    end

    defp completed_event(%{result: result}) do
      %{kind: :request_completed, at_ms: 10, data: %{result: result}}
    end

    defp completed_event(result) do
      %{kind: :request_completed, at_ms: 10, data: %{result: result}}
    end

    defp failed_event(reason) do
      %{kind: :request_failed, at_ms: 10, data: %{error: reason}}
    end
  end

  defmodule CoverageStubStatus do
    def broadcast(incoming, status, message, node_router) do
      send(self(), {:coverage_status, incoming, status, message, node_router})
      Process.get(:coverage_status_result, :ok)
    end
  end

  defmodule StubNodeRouter do
    def dispatch(%Zaq.Event{} = event), do: %{event | response: :ok}

    def call(:channels, Zaq.Channels.Router, :send_typing, _args), do: :ok
    def call(_role, module, function, args), do: apply(module, function, args)
  end

  @incoming %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

  @base_opts [
    agent_id: "stub",
    agent_module: StubAgent,
    server_manager_module: StubServerManager,
    factory_module: StubFactory,
    node_router: StubNodeRouter
  ]

  @base_incoming %Incoming{content: "q", channel_id: "c", provider: :web}

  describe "derive_scope/1" do
    test "returns bo:conv:<id> when metadata.conversation_id is set on :web provider" do
      incoming = %{@base_incoming | provider: :web, metadata: %{conversation_id: "conv-42"}}
      assert Executor.derive_scope(incoming) == "bo:conv:conv-42"
    end

    test "conversation_id takes priority over person_id for :web provider" do
      incoming = %{
        @base_incoming
        | provider: :web,
          person_id: 7,
          metadata: %{conversation_id: "conv-99"}
      }

      assert Executor.derive_scope(incoming) == "bo:conv:conv-99"
    end

    test "ignores conversation_id for non-web providers (falls through to person_id)" do
      incoming = %{
        @base_incoming
        | provider: :mattermost,
          person_id: 3,
          metadata: %{conversation_id: "conv-1"}
      }

      assert Executor.derive_scope(incoming) == "mattermost:person:3"
    end

    test "empty conversation_id falls through to person_id for :web" do
      incoming = %{
        @base_incoming
        | provider: :web,
          person_id: 5,
          metadata: %{conversation_id: ""}
      }

      assert Executor.derive_scope(incoming) == "bo:person:5"
    end

    test "includes channel and person_id" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 42}) == "bo:person:42"
    end

    test "normalizes mattermost provider" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 2, provider: :mattermost}) ==
               "mattermost:person:2"
    end

    test "normalizes colon-containing provider (email:imap → email_imap)" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 5, provider: :"email:imap"}) ==
               "email_imap:person:5"
    end

    test "falls back to bo:<session_id> when person_id is nil" do
      incoming = %{@base_incoming | person_id: nil, metadata: %{session_id: "sess-abc"}}
      assert Executor.derive_scope(incoming) == "bo:session:sess-abc"
    end

    test "returns 'anonymous' when both are absent" do
      incoming = %{@base_incoming | person_id: nil, metadata: %{}}
      assert Executor.derive_scope(incoming) == "anonymous"
    end
  end

  describe "run/2 — answering agent (no agent_id)" do
    defmodule StubSMAnswering do
      def ensure_server(_agent, server_id) do
        send(self(), {:ensure_server, server_id})
        {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
      end
    end

    defmodule StubFactoryAnswering do
      def answering_configured_agent,
        do: %Zaq.Agent.ConfiguredAgent{id: :answering, name: "answering", strategy: "react"}

      def ask_with_config(_server_id, _query, _agent, _opts \\ []),
        do: {:ok, %{request: make_ref(), events: [completed_event("hi")]}}

      def runtime_config(_agent), do: {:ok, %{system_prompt: "", tools: [], llm_opts: []}}

      defp completed_event(result) do
        %{kind: :request_completed, at_ms: 10, data: %{result: result}}
      end
    end

    defmodule StubFactoryWithUsage do
      def answering_configured_agent,
        do: %Zaq.Agent.ConfiguredAgent{id: :answering, name: "answering", strategy: "react"}

      def ask_with_config(_server_id, _query, _agent, _opts \\ []) do
        {:ok,
         %{
           request: make_ref(),
           events: [
             %{
               kind: :request_completed,
               at_ms: 10,
               data: %{
                 result: "the answer",
                 usage: %{input_tokens: 50, output_tokens: 25, total_tokens: 75}
               }
             }
           ]
         }}
      end

      def runtime_config(_agent), do: {:ok, %{system_prompt: "", tools: [], llm_opts: []}}
    end

    test "routes through answering configured agent, scoped per person and channel" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 5}

      result =
        Executor.run(incoming,
          answering_module: StubFactoryAnswering,
          factory_module: StubFactoryAnswering,
          server_manager_module: StubSMAnswering,
          node_router: StubNodeRouter
        )

      assert %Zaq.Engine.Messages.Outgoing{} = result
      assert_received {:ensure_server, "answering:bo:person:5"}
    end

    test "uses 'anonymous' scope when person_id and session_id are absent" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: nil}

      Executor.run(incoming,
        answering_module: StubFactoryAnswering,
        factory_module: StubFactoryAnswering,
        server_manager_module: StubSMAnswering,
        node_router: StubNodeRouter
      )

      assert_received {:ensure_server, "answering:anonymous"}
    end

    test "propagates answer text and token counts into Outgoing metadata" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 7}

      result =
        Executor.run(incoming,
          answering_module: StubFactoryWithUsage,
          factory_module: StubFactoryWithUsage,
          server_manager_module: StubSMAnswering,
          node_router: StubNodeRouter,
          scope: "bo:7"
        )

      assert %Zaq.Engine.Messages.Outgoing{} = result
      assert result.body == "the answer"
      assert result.metadata[:prompt_tokens] == 50
      assert result.metadata[:completion_tokens] == 25
      assert result.metadata[:total_tokens] == 75
      assert result.metadata[:error] == false
    end

    test "does not read prompt and completion aliases from runtime measurements" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 7}

      Process.put(:coverage_await_result, {
        :ok,
        %{
          result: "the answer",
          usage: %{prompt_tokens: 50, completion_tokens: 25, total_tokens: 75}
        }
      })

      result =
        Executor.run(incoming,
          agent_id: "stub",
          agent_module: CoverageStubAgent,
          server_manager_module: CoverageStubServerManager,
          factory_module: CoverageStubFactory,
          status_module: CoverageStubStatus,
          node_router: StubNodeRouter,
          scope: "coverage"
        )

      assert result.metadata[:prompt_tokens] == 50
      assert result.metadata[:completion_tokens] == 25
      assert result.metadata[:total_tokens] == 75
      refute Map.has_key?(result.metadata[:measurements], "prompt_tokens")
      refute Map.has_key?(result.metadata[:measurements], "completion_tokens")
    end

    test "nil confidence from stub does not appear as 0.0 in metadata" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 8}

      result =
        Executor.run(incoming,
          answering_module: StubFactoryWithUsage,
          factory_module: StubFactoryWithUsage,
          server_manager_module: StubSMAnswering,
          node_router: StubNodeRouter,
          scope: "bo:8"
        )

      # nil confidence (no logprobs) must NOT be coerced to 0.0 —
      # 0.0 is the explicit no-answer sentinel used by the history guard.
      assert is_nil(result.metadata[:confidence_score])
    end
  end

  describe "run/2 :scope opt" do
    test "loads selected configured agent by name when agent_id is absent" do
      opts =
        @base_opts
        |> Keyword.delete(:agent_id)
        |> Keyword.put(:agent_name, "Named Stub Agent")
        |> Keyword.put(:scope, "workflow")

      Executor.run(@incoming, opts)

      assert_received {:ensure_server, %{id: 88, name: "Named Stub Agent"},
                       "Named Stub Agent:workflow"}
    end

    test "surfaces agent lookup errors from selected agent name" do
      outgoing =
        Executor.run(@incoming,
          agent_name: "Missing",
          agent_module: MissingNamedStubAgent,
          server_manager_module: StubServerManager,
          factory_module: StubFactory,
          node_router: StubNodeRouter
        )

      assert outgoing.metadata[:error] == true
      assert outgoing.metadata[:error_type] == nil
      assert outgoing.metadata[:reason] == ":agent_not_found"
    end

    test "with explicit :scope uses agent name as server id — {agent_name}:{scope}" do
      opts = Keyword.put(@base_opts, :scope, "99")

      Executor.run(@incoming, opts)

      assert_received {:ensure_server, _configured_agent, "Stub Agent:99"}
    end

    test "without :scope derives scope from incoming (channel:identity)" do
      # @incoming has provider: :web → "bo", no person_id → "anonymous"
      Executor.run(@incoming, @base_opts)

      assert_received {:ensure_server, _configured_agent, "Stub Agent:anonymous"}
    end
  end

  describe "coverage gaps" do
    test "derive_scope supports binary provider normalization" do
      incoming = %Incoming{
        content: "hello",
        channel_id: "c1",
        provider: "email:imap",
        person_id: 5
      }

      assert Executor.derive_scope(incoming) == "email_imap:person:5"
    end

    test "system_prompt override replaces configured_agent.job when non-empty binary" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 9}

      Executor.run(incoming,
        agent_id: "stub",
        agent_module: CoverageStubAgent,
        server_manager_module: CoverageStubServerManager,
        factory_module: CoverageStubFactory,
        status_module: CoverageStubStatus,
        node_router: StubNodeRouter,
        system_prompt: "temporary job override"
      )

      assert_received {:coverage_ask, _content, configured_agent, _tool_context}
      assert configured_agent.job == "temporary job override"
      assert configured_agent.name == "Stub Agent"
    end

    test "extract_metrics reads string-key usage and nested string result" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 11}

      Process.put(
        :coverage_await_result,
        {:ok,
         %{
           "result" => %{
             "usage" => %{
               "prompt_tokens" => 11,
               "completion_tokens" => 22,
               "total_tokens" => 33
             }
           }
         }}
      )

      outgoing =
        Executor.run(incoming,
          agent_id: "stub",
          agent_module: CoverageStubAgent,
          server_manager_module: CoverageStubServerManager,
          factory_module: CoverageStubFactory,
          status_module: CoverageStubStatus,
          node_router: StubNodeRouter,
          scope: "coverage"
        )

      assert outgoing.metadata[:prompt_tokens] == 11
      assert outgoing.metadata[:completion_tokens] == 22
      assert outgoing.metadata[:total_tokens] == 33
    end

    test "confidence telemetry emits bucket metrics for high mid and low scores" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 12}

      for {score, _bucket} <- [
            {0.95, "qa.answer.confidence.bucket.gt_90"},
            {0.8, "qa.answer.confidence.bucket.gt_70"},
            {0.5, "qa.answer.confidence.bucket.lt_70"}
          ] do
        Process.put(
          :coverage_await_result,
          {:ok,
           %{
             result: %{logprobs: [%{logprob: :math.log(score)}]}
           }}
        )

        outgoing =
          Executor.run(incoming,
            agent_id: "stub",
            agent_module: CoverageStubAgent,
            server_manager_module: CoverageStubServerManager,
            factory_module: CoverageStubFactory,
            status_module: CoverageStubStatus,
            node_router: StubNodeRouter,
            scope: "coverage"
          )

        assert_in_delta outgoing.metadata[:confidence_score], score, 0.000001
      end
    end

    test "status fallback keeps original incoming when status module returns non-Incoming" do
      incoming = %Incoming{
        content: "hello",
        channel_id: "c1",
        provider: :web,
        person_id: 13,
        metadata: %{request_id: "req-13"}
      }

      Process.put(:coverage_status_result, :ok)

      outgoing =
        Executor.run(incoming,
          agent_id: "stub",
          agent_module: CoverageStubAgent,
          server_manager_module: CoverageStubServerManager,
          factory_module: CoverageStubFactory,
          status_module: CoverageStubStatus,
          node_router: StubNodeRouter,
          scope: "coverage"
        )

      assert outgoing.metadata[:error] == false
      assert_received {:coverage_ask, _content, _configured_agent, tool_context}
      assert tool_context.incoming == incoming
    end

    test "tool_context carries the event actor when an :event opt is given" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 21}
      actor = %{id: "u1", name: "alice", provider: :web, person_id: 21}
      event = Zaq.Event.new(incoming, :agent, actor: actor)

      Executor.run(incoming,
        agent_id: "stub",
        agent_module: CoverageStubAgent,
        server_manager_module: CoverageStubServerManager,
        factory_module: CoverageStubFactory,
        status_module: CoverageStubStatus,
        node_router: StubNodeRouter,
        scope: "coverage",
        event: event
      )

      assert_received {:coverage_ask, _content, _configured_agent, tool_context}
      assert tool_context.actor == actor
    end

    test "tool_context actor is nil without an :event opt" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 22}

      Executor.run(incoming,
        agent_id: "stub",
        agent_module: CoverageStubAgent,
        server_manager_module: CoverageStubServerManager,
        factory_module: CoverageStubFactory,
        status_module: CoverageStubStatus,
        node_router: StubNodeRouter,
        scope: "coverage"
      )

      assert_received {:coverage_ask, _content, _configured_agent, tool_context}
      assert is_nil(tool_context.actor)
    end

    test "error telemetry classifies tuple and struct reasons" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 14}

      for {reason, expected_error_type} <- [
            {{:timeout, 5000}, "timeout"},
            {%RuntimeError{message: "boom"}, "RuntimeError"}
          ] do
        Process.put(:coverage_await_result, {:error, reason})

        outgoing =
          Executor.run(incoming,
            agent_id: "stub",
            agent_module: CoverageStubAgent,
            server_manager_module: CoverageStubServerManager,
            factory_module: CoverageStubFactory,
            status_module: CoverageStubStatus,
            node_router: StubNodeRouter,
            scope: "coverage"
          )

        assert outgoing.metadata[:error] == true
        assert String.contains?(outgoing.metadata[:reason], expected_error_type)
      end
    end

    test "non-binary question bypasses timestamp prefixing" do
      incoming = %Incoming{content: "hello", channel_id: "c1", provider: :web, person_id: 15}

      Executor.run(incoming,
        agent_id: "stub",
        agent_module: CoverageStubAgent,
        server_manager_module: CoverageStubServerManager,
        factory_module: CoverageStubFactory,
        status_module: CoverageStubStatus,
        node_router: StubNodeRouter,
        scope: "coverage",
        question: {:raw_question, "keep as-is"}
      )

      assert_received {:coverage_ask, {:raw_question, "keep as-is"}, _configured_agent,
                       _tool_context}
    end
  end
end
