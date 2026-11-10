defmodule Zaq.Agent.RequestInspectionTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts.People
  alias Zaq.Agent.{Factory, RequestControl, ServerManager, StreamEvents}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.{AgentConfig, MultiAgentOpenAIStub, OpenAIStub}

  setup tags do
    if tags[:native] do
      Code.ensure_loaded!(AgentConfig)

      handler = fn _conn, body ->
        request = Jason.decode!(body)
        question = MultiAgentOpenAIStub.latest_user_message(request)

        text =
          if question == "Long native stream", do: long_native_text(), else: question

        response =
          if question == "Long native stream",
            do: long_text_sse(text, request["model"]),
            else: MultiAgentOpenAIStub.text_sse(text, request["model"])

        {200, String.replace(response, "resp_test", "resp_#{Ecto.UUID.generate()}")}
      end

      {child, endpoint} = OpenAIStub.server(handler, self())
      start_supervised!(child)

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

      {:ok, person} = People.create_person(%{full_name: "Native inspection owner"})
      actor = %{person: %{id: person.id}}

      {:ok, agent} =
        Zaq.Agent.create_agent(%{
          name: "Native inspection #{System.unique_integer([:positive])}",
          job: "Answer briefly.",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          active: true,
          model_max_context_tokens: 20_000
        })

      scope = "native-inspection:#{Ecto.UUID.generate()}"

      assert {:ok, server} =
               ServerManager.ensure_server(agent, scope, nil,
                 actor: actor,
                 config: AgentConfig
               )

      on_exit(fn -> ServerManager.stop_server(agent, scope) end)
      %{agent: agent, actor: actor, scope: scope, server: server, pid: GenServer.whereis(server)}
    else
      :ok
    end
  end

  test "unavailable native state is not acceptance proof" do
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:error, :stale_runtime} = Factory.request_state(pid, "absent")
  end

  test "request state rejects invalid runtime and request identifiers" do
    pid = self()

    assert {:error, :stale_runtime} = Factory.request_state(:not_a_pid, "request")
    assert {:error, :stale_runtime} = Factory.request_state(pid, :not_a_request_id)
  end

  test "idle inspection reports unavailable native state after runtime termination" do
    pid = spawn(fn -> :ok end)
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}

    assert {:error, :native_state_unavailable} = Factory.history_runtime_idle(pid)
  end

  @tag :native
  @tag timeout: 180_000
  test "a real native stream beyond trace capacity returns the complete answer without an archive",
       ctx do
    {request, result} = consume_native(ctx, "Long native stream")
    text = long_native_text()
    assert result.answer == text
    assert {:ok, %{raw_state: raw}} = Jido.AgentServer.status(ctx.pid)
    native_trace = raw.__strategy__.request_traces[request.id]
    assert native_trace.truncated?
    assert length(native_trace.events) == 2_000
    assert Enum.count(native_trace.events, &(&1.kind == :llm_delta)) < 2_010
    assert result.termination_reason == :final_answer
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined
    assert {:error, :not_found} = RequestControl.find_native_request(ctx.scope, ctx.actor)
    {later, later_result} = consume_native(ctx, "Different subsequent answer")
    refute later.id == request.id
    assert later_result.answer == "Different subsequent answer"

    stop_native(ctx)
    assert {:error, :stale_runtime} = Factory.request_state(ctx.pid, request.id)
    assert {:error, :not_found} = RequestControl.find_native_request(ctx.scope, ctx.actor)
  end

  @tag :native
  @tag timeout: 300_000
  test "native default 100-request eviction does not create an application archive",
       ctx do
    {first, _} = consume_native(ctx, "Oldest answer")
    assert {:ok, %{raw_state: initial}} = Jido.AgentServer.status(ctx.pid)
    assert (get_in(initial, [:__request_tracking__, :max_requests]) || 100) == 100

    for n <- 1..100 do
      {_request, result} = consume_native(ctx, "New answer #{n}")
      assert result.answer == "New answer #{n}"
    end

    assert {:ok, %{raw_state: raw}} = Jido.AgentServer.status(ctx.pid)
    assert map_size(raw.requests) == 100
    refute Map.has_key?(raw.requests, first.id)
    assert {:error, :not_found} = Factory.request_state(ctx.pid, first.id)
    assert {:error, :not_found} = RequestControl.find_native_request(ctx.scope, ctx.actor)
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined

    stop_native(ctx)
    assert {:error, :not_found} = RequestControl.find_native_request(ctx.scope, ctx.actor)
  end

  defp stop_native(ctx) do
    monitor = Process.monitor(ctx.pid)
    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 10_000
  end

  @tag :native
  test "an unavailable runtime cannot restart ServerManager during shutdown",
       ctx do
    {request, _} = consume_native(ctx, "Archived before unavailable shutdown")
    monitor = Process.monitor(ctx.pid)
    manager = Process.whereis(ServerManager)
    assert :erlang.suspend_process(ctx.pid)

    on_exit(fn ->
      if Process.info(ctx.pid, :status) == {:status, :suspended},
        do: :erlang.resume_process(ctx.pid)
    end)

    assert :ok = ServerManager.stop_server(ctx.agent, ctx.scope)
    assert Process.whereis(ServerManager) == manager
    assert :ets.whereis(:zaq_agent_request_observations) == :undefined

    if Process.info(ctx.pid, :status) == {:status, :suspended},
      do: :erlang.resume_process(ctx.pid)

    assert_receive {:DOWN, ^monitor, :process, _, _}, 10_000
    assert {:error, :stale_runtime} = Factory.request_state(ctx.pid, request.id)
  end

  defp consume_native(ctx, question) do
    {request, result} =
      Task.async(fn -> do_consume_native(ctx, question) end) |> Task.await(120_000)

    {request, result}
  end

  defp do_consume_native(ctx, question) do
    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(ctx.server, question, ctx.agent,
               tool_context: %{actor: ctx.actor}
             )

    incoming = %Incoming{content: question, channel_id: ctx.scope, provider: nil}

    assert {:ok, result} =
             StreamEvents.consume(events, incoming,
               request: request,
               actor: ctx.actor,
               execution_scope: ctx.scope,
               runtime_pid: ctx.pid,
               server_id: ctx.server,
               agent: ctx.agent
             )

    # The stream sink can drain ahead of AgentServer's own event mailbox.
    await_native_idle(ctx.pid, request.id, System.monotonic_time(:millisecond) + 60_000)

    assert {:ok, %{status: :completed, accepting?: false}} =
             Factory.request_state(ctx.pid, request.id)

    {request, result}
  end

  defp await_native_idle(pid, id, deadline) do
    # Awaiting through the native stream is not a barrier for AgentServer's own
    # mailbox. Read its real state until both the request and strategy are idle.
    state =
      try do
        GenServer.call(pid, :get_state, 60_000)
      catch
        :exit, reason ->
          flunk(
            "native state unavailable: #{inspect(reason)}; stack #{inspect(Process.info(pid, :current_stacktrace))}"
          )
      end

    assert {:ok, %{agent: %{state: raw}}} = state

    if raw.requests[id].status == :completed do
      assert {:ok, %{accepting?: false}} = Factory.request_state(pid, id)
    end

    case {raw.requests[id].status, raw.__strategy__.status, raw.__strategy__.active_request_id} do
      {:completed, :completed, _active_id} ->
        :ok

      state ->
        diagnostic = %{
          state: state,
          expected: id,
          requests: map_size(raw.requests),
          last_events:
            raw.__strategy__.request_traces[id].events |> Enum.take(-6) |> Enum.map(& &1.kind)
        }

        assert System.monotonic_time(:millisecond) < deadline,
               "native completion did not settle: #{inspect(diagnostic)}"

        receive do
        after
          10 -> await_native_idle(pid, id, deadline)
        end
    end
  end

  defp long_text_sse(text, model) do
    deltas =
      Enum.map_join(String.graphemes(text), fn delta ->
        "event: response.output_text.delta\ndata: #{Jason.encode!(%{"delta" => delta})}\n\n"
      end)

    # Reuse the real terminal shape without inserting an additional text delta.
    [_, terminal] =
      String.split(MultiAgentOpenAIStub.text_sse("", model), "event: response.completed",
        parts: 2
      )

    deltas <> "event: response.completed" <> terminal
  end

  defp long_native_text do
    # Distinct deltas detect reordering; repeated identical characters cannot.
    Enum.map_join(1..2_010, fn index -> <<0x4E00 + index::utf8>> end)
  end
end
