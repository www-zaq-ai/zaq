defmodule Zaq.Agent.ExecutorTest do
  use ExUnit.Case, async: true

  doctest Zaq.Agent.Executor

  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming

  defmodule StubAgent do
    def get_active_agent(_agent_id), do: {:ok, %{id: 77, name: "Stub Agent"}}
  end

  defmodule StubServerManager do
    def ensure_server(configured_agent, server_id, _incoming) do
      send(self(), {:ensure_server, configured_agent, server_id})
      {:ok, :stub_server_scoped}
    end
  end

  defmodule StubFactory do
    def ask_with_config(_server, _content, _configured_agent, _opts \\ []), do: {:ok, :request}
    def await(:request, timeout: 45_000), do: {:ok, %{result: "stubbed answer"}}
    def answering_configured_agent, do: %{id: :answering, name: "answering"}
  end

  defmodule StubNodeRouter do
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

      assert Executor.derive_scope(incoming) == "mattermost:3"
    end

    test "empty conversation_id falls through to person_id for :web" do
      incoming = %{
        @base_incoming
        | provider: :web,
          person_id: 5,
          metadata: %{conversation_id: ""}
      }

      assert Executor.derive_scope(incoming) == "bo:5"
    end

    test "includes channel and person_id" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 42}) == "bo:42"
    end

    test "normalizes mattermost provider" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 2, provider: :mattermost}) ==
               "mattermost:2"
    end

    test "normalizes colon-containing provider (email:imap → email_imap)" do
      assert Executor.derive_scope(%{@base_incoming | person_id: 5, provider: :"email:imap"}) ==
               "email_imap:5"
    end

    test "falls back to bo:<session_id> when person_id is nil" do
      incoming = %{@base_incoming | person_id: nil, metadata: %{session_id: "sess-abc"}}
      assert Executor.derive_scope(incoming) == "bo:sess-abc"
    end

    test "returns 'anonymous' when both are absent" do
      incoming = %{@base_incoming | person_id: nil, metadata: %{}}
      assert Executor.derive_scope(incoming) == "anonymous"
    end
  end

  describe "run/2 — answering agent (no agent_id)" do
    defmodule StubSMAnswering do
      def ensure_server(_agent, server_id, _spawn_opts) do
        send(self(), {:ensure_server, server_id})
        {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
      end
    end

    defmodule StubFactoryAnswering do
      def answering_configured_agent,
        do: %Zaq.Agent.ConfiguredAgent{id: :answering, name: "answering", strategy: "react"}

      def ask_with_config(_server_id, _query, _agent, _opts \\ []), do: {:ok, make_ref()}
      def await(_ref, _opts), do: {:ok, "hi"}
      def runtime_config(_agent), do: {:ok, %{system_prompt: "", tools: [], llm_opts: []}}
    end

    defmodule StubFactoryWithUsage do
      def answering_configured_agent,
        do: %Zaq.Agent.ConfiguredAgent{id: :answering, name: "answering", strategy: "react"}

      def ask_with_config(_server_id, _query, _agent, _opts \\ []), do: {:ok, make_ref()}

      def await(_ref, _opts) do
        {:ok,
         %{
           result: "the answer",
           usage: %{prompt_tokens: 50, completion_tokens: 25, total_tokens: 75}
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
      assert_received {:ensure_server, "answering:bo:5"}
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
end
