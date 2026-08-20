defmodule Zaq.Agent.Plugin.ContextWindowPluginTest do
  @moduledoc """
  Covers the two lifecycle cases the plugin owns: cold spawn (`mount/2`) and a
  warm server compacting itself after a completed request.
  """

  use Zaq.DataCase, async: false

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Accounts.Person
  alias Zaq.Agent.Plugin.ContextWindowPlugin, as: Plugin
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.TestSupport.LLMSSEStub

  @budget 60

  defmodule EchoTool do
    @moduledoc false
    use Jido.Action,
      name: "echo",
      description: "Echoes a long payload back",
      schema: [text: [type: :string, required: true]]

    def run(%{text: text}, _context) do
      {:ok, %{result: String.duplicate("#{text} padding words here ", 10)}}
    end
  end

  defmodule Agent do
    @moduledoc false
    use Jido.AI.Agent,
      name: "context_window_plugin_probe",
      description: "probe agent",
      request_policy: :reject,
      plugins: [Zaq.Agent.Plugin.ContextWindowPlugin],
      request_transformer: Zaq.Agent.ContextWindow,
      tools: [EchoTool]

    def strategy_opts, do: super() |> Keyword.delete(:model)
  end

  defp insert_conversation do
    person =
      Repo.insert!(%Person{
        full_name: "Ctx Window Person #{System.unique_integer([:positive])}",
        email: "ctx-#{System.unique_integer([:positive])}@example.com"
      })

    Repo.insert!(%Conversation{person_id: person.id, channel_type: "web", status: "open"})
  end

  defp insert_messages(conversation, count) do
    Enum.each(1..count, fn i ->
      Repo.insert!(%Message{
        conversation_id: conversation.id,
        role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
        content: "history message number #{i} with a few padding words attached",
        inserted_at: DateTime.add(DateTime.utc_now(), i, :second)
      })
    end)
  end

  # Mirrors what jido passes mount/2: the agent struct with initial_state already
  # in place, before the strategy runs.
  defp agent_struct(server_id, state) do
    %Jido.Agent{id: server_id, agent_module: Agent, name: "probe", state: state}
  end

  defp tool_context(budget), do: %{tool_context: %{memory_context_max_size: budget}}

  defp context_tokens(%AIContext{} = ctx) do
    TokenEstimator.estimate(ctx.system_prompt || "") +
      Enum.reduce(ctx.entries, 0, fn e, acc ->
        acc + TokenEstimator.estimate(to_string(e.content || ""))
      end)
  end

  describe "cold spawn — mount/2" do
    import ExUnit.CaptureLog

    test "returns an empty context when the conversation has no messages" do
      conversation = insert_conversation()

      {:ok, context} =
        Plugin.mount(
          agent_struct("agent:web:conv:#{conversation.id}", tool_context(@budget)),
          %{}
        )

      assert %AIContext{} = context
      assert context.entries == []
    end

    test "hydrates from messages saved in the database" do
      conversation = insert_conversation()
      insert_messages(conversation, 4)

      {:ok, context} =
        Plugin.mount(
          agent_struct("agent:web:conv:#{conversation.id}", tool_context(5_000)),
          %{}
        )

      contents = context |> AIContext.to_messages() |> Enum.map(&to_string(&1.content))

      assert length(contents) == 4
      assert Enum.any?(contents, &(&1 =~ "history message number 1"))
      assert Enum.any?(contents, &(&1 =~ "history message number 4"))
    end

    test "trims the hydrated history to the budget, keeping the newest messages" do
      conversation = insert_conversation()
      insert_messages(conversation, 30)

      {:ok, context} =
        Plugin.mount(
          agent_struct("agent:web:conv:#{conversation.id}", tool_context(@budget)),
          %{}
        )

      contents = context |> AIContext.to_messages() |> Enum.map(&to_string(&1.content))

      assert context_tokens(context) <= @budget
      assert length(contents) < 30
      assert Enum.any?(contents, &(&1 =~ "history message number 30"))
      refute Enum.any?(contents, &(&1 =~ "history message number 1 "))
    end

    test "returns an empty context for a scope that has no history to load" do
      {:ok, context} =
        Plugin.mount(agent_struct("agent:workflow:run:abc", tool_context(@budget)), %{})

      assert %AIContext{entries: []} = context
    end

    test "falls back to an empty context when history hydration raises" do
      log =
        capture_log(fn ->
          assert {:ok, %AIContext{entries: []}} =
                   Plugin.mount(agent_struct(nil, tool_context(@budget)), %{})
        end)

      assert log =~ "ContextWindow could not hydrate history for nil"
    end

    test "trims a caller-supplied context rather than replacing it with history" do
      conversation = insert_conversation()
      insert_messages(conversation, 4)

      supplied =
        Enum.reduce(1..20, AIContext.new(), fn i, ctx ->
          AIContext.append_user(ctx, "supplied turn #{i} with several padding words here")
        end)

      state = Map.put(tool_context(@budget), :context, supplied)

      {:ok, context} = Plugin.mount(agent_struct("agent:web:conv:#{conversation.id}", state), %{})

      contents = context |> AIContext.to_messages() |> Enum.map(&to_string(&1.content))

      assert context_tokens(context) <= @budget
      assert Enum.all?(contents, &(&1 =~ "supplied turn"))
      refute Enum.any?(contents, &(&1 =~ "history message"))
    end
  end

  describe "warm server — ai.react.context.modify" do
    setup do
      {child_spec, base_url} = LLMSSEStub.server(2, self())
      {:ok, _} = start_supervised(child_spec)
      %{base_url: base_url}
    end

    defp start_agent(base_url, budget) do
      {:ok, pid} =
        start_supervised(
          {Jido.AgentServer,
           [
             agent: Agent,
             jido: Zaq.Agent.Jido,
             registry: Jido.registry_name(Zaq.Agent.Jido),
             id: "ctx-plugin-#{System.unique_integer([:positive])}",
             initial_state: %{
               model: %{provider: :openai, id: "test-model", base_url: base_url},
               tool_context: %{memory_context_max_size: budget}
             }
           ]}
        )

      pid
    end

    defp strategy_context(pid) do
      {:ok, %{agent: agent}} = Jido.AgentServer.state(pid)
      get_in(agent.state, [:__strategy__, :context])
    end

    defp await_context(pid, predicate, attempts \\ 60)

    defp await_context(pid, _predicate, 0), do: strategy_context(pid)

    defp await_context(pid, predicate, attempts) do
      context = strategy_context(pid)

      if predicate.(context) do
        context
      else
        Process.sleep(25)
        await_context(pid, predicate, attempts - 1)
      end
    end

    test "leaves non-completed signals unchanged" do
      signal = Jido.Signal.new!(%{type: "ai.request.started", source: "zaq:test"})

      assert {:ok, ^signal, %{}} = Plugin.prepare_signal(signal, %{agent: %{}})
    end

    test "compacts the live __strategy__ context after a completed request",
         %{base_url: base_url} do
      pid = start_agent(base_url, @budget)

      assert {:ok, _} =
               Agent.ask_sync(pid, "the current question",
                 timeout: 30_000,
                 llm_opts: [api_key: "test-key"]
               )

      # The run itself commits its turns into __strategy__.context at
      # :request_completed. The plugin's prepare_signal casts the compaction back
      # at the server, so the committed context settles inside the budget.
      context = await_context(pid, &(context_tokens(&1) <= @budget))

      assert context_tokens(context) <= @budget

      contents = context |> AIContext.to_messages() |> Enum.map(&to_string(&1.content))
      assert Enum.any?(contents, &(&1 =~ "the current question"))
    end

    test "the same run left unbudgeted grows well past the small budget" do
      # Falsifies the two tests above: with a budget the run cannot reach, the
      # plugin has nothing to compact and the committed context is far larger
      # than @budget — so the bounded results above are the plugin working, not a
      # run that happened to be small.
      {child_spec, base_url} = LLMSSEStub.server(2, self())
      {:ok, _} = start_supervised(child_spec)
      pid = start_agent(base_url, 100_000)

      assert {:ok, _} =
               Agent.ask_sync(pid, "the current question",
                 timeout: 30_000,
                 llm_opts: [api_key: "test-key"]
               )

      context = await_context(pid, &(context_tokens(&1) > @budget))

      assert context_tokens(context) > @budget

      assert Jido.AgentServer.state(pid)
             |> elem(1)
             |> Map.get(:agent)
             |> then(& &1.state[:__strategy__][:applied_context_ops]) == []
    end

    test "records the compaction through the sanctioned context-op path",
         %{base_url: base_url} do
      pid = start_agent(base_url, @budget)

      assert {:ok, _} =
               Agent.ask_sync(pid, "the current question",
                 timeout: 30_000,
                 llm_opts: [api_key: "test-key"]
               )

      _ = await_context(pid, &(context_tokens(&1) <= @budget))

      {:ok, %{agent: agent}} = Jido.AgentServer.state(pid)

      assert agent.state[:__strategy__][:applied_context_ops] != [],
             "the compaction did not go through ai.react.context.modify"
    end
  end
end
