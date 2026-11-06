defmodule ZaqWeb.NestedActionTracesBrowserTest do
  @moduledoc "Approved nested trace journeys over the real BO, native Agent and workflow runtime."
  use ZaqWeb.ConnCase, async: false

  @moduletag :real_browser
  @moduletag :paradedb

  import Ecto.Query
  import Mox
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.ServerManager
  alias Zaq.Agent.Tools.Workflow.RunAgent
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Engine.Workflows
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.TestSupport.{HistoryBrowser, MultiAgentOpenAIStub, OpenAIStub}

  setup :verify_on_exit!

  defmodule Branch do
    use Jido.Action,
      name: "browser_trace_branch",
      description: "A real composed branch for the approved workflow browser journey",
      schema: []

    alias Zaq.Agent.Tools.ActionContract
    alias Zaq.TestSupport.NestedActionProbe

    @impl Jido.Action
    def run(_, context) do
      ActionContract.execute(
        NestedActionProbe,
        %{depth: 0},
        context,
        timeout: 0,
        max_retries: 0
      )
    end
  end

  defmodule ExternalRead do
    use Jido.Action,
      name: "browser_external_read",
      description: "A gated local HTTP dependency for workflow browser evidence",
      schema: [
        endpoint: [type: :string, required: true],
        api_key: [type: :string, required: true]
      ]

    @impl Jido.Action
    def run(%{endpoint: endpoint}, _) do
      with {:ok, %{status: 200}} <- Req.get(endpoint, receive_timeout: 30_000) do
        {:ok, %{value: 42, password: "PRIVATE_CHILD_RESULT"}}
      end
    end
  end

  defmodule WorkflowAction do
    use Zaq.Engine.Workflows.Action,
      name: "browser_trace_workflow",
      description: "Compose a successful branch and an independently gated sibling",
      schema: [endpoint: [type: :string, required: true]],
      output_schema: [value: [type: :integer, required: true]]

    alias Zaq.Agent.Tools.ActionContract

    @impl Jido.Action
    def run(%{endpoint: endpoint}, context) do
      with {:ok, %{value: 42}} <- ActionContract.execute(Branch, %{}, context, timeout: 0),
           {:ok, _} <-
             ActionContract.execute(
               ExternalRead,
               %{endpoint: endpoint, api_key: "PRIVATE_CHILD_ARGUMENT"},
               context,
               timeout: 0
             ) do
        {:ok, %{value: 42}}
      end
    end
  end

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 180_000
    @tag browser_engine: engine
    test "#{engine}: native child evidence and workflow live/completed/cancelled reload" do
      owner = self()
      set_mox_global()
      stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
      stub(Zaq.NodeRouterMock, :dispatch, &Zaq.NodeRouter.dispatch/1)
      Zaq.DataCase.isolate_event_registry()
      restore_runtime_dependencies()
      Chunk.create_table(1536)
      ChunkLanguages.invalidate()
      on_exit(fn -> ChunkLanguages.invalidate() end)

      user = admin_fixture()
      staff_role = role_fixture(%{name: "staff"})
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
      other = user_fixture()

      {:ok, forbidden} =
        Conversations.create_conversation(%{channel_type: "bo", user_id: other.id})

      {:ok, _} =
        Conversations.add_message(forbidden, %{
          role: "assistant",
          content: "FORBIDDEN_NESTED_HISTORY"
        })

      {:ok, document} = Document.upsert(%{source: "nested-traces-#{unquote(engine)}/guide.md"})
      {:ok, _} = Permissions.grant_public(document)

      {:ok, chunk} =
        Chunk.create(%{
          document_id: document.id,
          chunk_index: 0,
          content: "nestedneedle verified trace evidence",
          language: "simple"
        })

      {server, endpoint} =
        OpenAIStub.server(
          fn conn, body ->
            if String.ends_with?(conn.request_path, "/gate") do
              send(owner, {:workflow_gate_wait, self()})

              receive do
                :release_workflow_gate -> {200, Jason.encode!(%{ok: true})}
              after
                30_000 -> raise "Browser did not release workflow dependency"
              end
            else
              provider_reply(body, chunk)
            end
          end,
          owner
        )

      start_supervised!(server)

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "fixture-key"})

      {:ok, agent} =
        Zaq.Agent.create_agent(%{
          name: "Nested traces #{unquote(engine)}",
          job: "Search the knowledge base and answer briefly.",
          model: "gpt-4.1-mini",
          model_max_context_tokens: 128_000,
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: ["answering.search_knowledge_base"],
          conversation_enabled: true,
          active: true,
          advanced_options: %{"stream" => true}
        })

      on_exit(fn -> ServerManager.stop_server(agent) end)

      {:ok, workflow} =
        Workflows.create_workflow(%{
          name: "Nested workflow #{unquote(engine)}",
          nodes: [
            %{
              name: "review",
              type: "action",
              module: inspect(WorkflowAction),
              params: %{endpoint: endpoint <> "/gate"},
              index: 0
            }
          ],
          edges: []
        })

      runs =
        Map.new(["complete", "cancel"], fn mode ->
          {:ok, run} =
            Workflows.create_run(workflow, %{
              "request" => nil,
              "assigns" => %{"trigger_type" => "manual"}
            })

          {mode, run}
        end)

      runs = Map.merge(runs, agent_workflow_runs(agent.id))

      try do
        HistoryBrowser.run!(
          %{
            runner: "test/e2e/support/nested-action-traces-browser.cjs",
            engine: unquote(engine),
            username: user.username,
            agent_id: agent.id,
            forbidden_id: forbidden.id
          },
          fn
            "agent-saved", state ->
              message =
                Repo.one!(
                  from m in Message,
                    join: c in Conversation,
                    on: c.id == m.conversation_id,
                    where:
                      c.user_id == ^user.id and m.role == "assistant" and
                        m.content == "Nested trace answer",
                    order_by: [desc: m.inserted_at],
                    limit: 1
                )

              assert [%{"id" => "opaque.native.root", "state" => "succeeded"}] =
                       ToolStep.project(message.trace)

              children = Enum.filter(message.trace, &(&1["origin"] == "zaq_action"))
              assert length(children) >= 3
              assert Enum.all?(children, &(&1["parent_id"] == "opaque.native.root"))
              {%{conversation_id: message.conversation_id, child_id: hd(children)["id"]}, state}

            "trace-role-revoke", state ->
              assert {:ok, _} =
                       Accounts.update_user(Accounts.get_user!(user.id), %{role_id: staff_role.id})

              {%{}, state}

            "trace-role-restore", state ->
              assert {:ok, _} =
                       Accounts.update_user(Accounts.get_user!(user.id), %{role_id: user.role_id})

              {%{}, state}

            mode, state when mode in ["agent-completed", "agent-failed", "agent-early-failed"] ->
              run = runs[mode]

              assert {:ok, finished} =
                       Task.async(fn -> Workflows.start_run(run) end) |> Task.await(10_000)

              expected_status = if mode == "agent-completed", do: "completed", else: "failed"
              assert finished.status == expected_status
              [step] = Workflows.list_step_runs(run.id)
              assert step.status == expected_status
              trace = step.results["trace"]
              assert is_list(trace)
              children = Enum.filter(trace, &(&1["origin"] == "zaq_action"))
              assert_agent_workflow_evidence(mode, step, trace, children)

              {%{
                 workflow_id: run.workflow_id,
                 run_id: run.id,
                 step_id: step.id,
                 child_id: List.first(children) && hd(children)["id"]
               }, state}

            stage, state when stage in ["workflow-complete-start", "workflow-cancel-start"] ->
              run =
                if stage == "workflow-complete-start", do: runs["complete"], else: runs["cancel"]

              :ok = Workflows.start_run_async(run)
              assert_receive {:workflow_gate_wait, worker}, 10_000
              [{pid, _}] = Registry.lookup(Zaq.Engine.Workflows.RunRegistry, run.id)
              monitor = Process.monitor(pid)
              [step] = Workflows.list_step_runs(run.id)
              starts = Enum.filter(step.trace_events, &(&1["kind"] == "tool_started"))
              assert length(starts) == 3
              branch = Enum.find(starts, &(&1["tool_name"] == "browser_trace_branch"))
              nested = Enum.find(starts, &(&1["tool_name"] == "nested_action_probe"))
              sibling = Enum.find(starts, &(&1["tool_name"] == "browser_external_read"))
              assert nested["data"]["parent_id"] == branch["tool_call_id"]
              refute Jason.encode!(step.trace_events) =~ "PRIVATE_CHILD_ARGUMENT"

              {%{
                 workflow_id: workflow.id,
                 run_id: run.id,
                 step_id: step.id,
                 branch_id: branch["tool_call_id"],
                 nested_id: nested["tool_call_id"],
                 sibling_id: sibling["tool_call_id"]
               }, Map.merge(state, %{run: run, worker: worker, pid: pid, monitor: monitor})}

            "workflow-complete-release", state ->
              %{monitor: monitor, pid: pid} = state
              send(state.worker, :release_workflow_gate)
              assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 10_000
              assert Workflows.get_run!(state.run.id).status == "completed"
              [step] = Workflows.list_step_runs(state.run.id)
              refute Jason.encode!(step.trace_events) =~ "PRIVATE_CHILD_RESULT"
              {%{}, state}

            "workflow-cancelled", state ->
              %{monitor: monitor, pid: pid} = state
              assert Workflows.get_run!(state.run.id).status == "cancelled"
              assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 10_000
              send(state.worker, :release_workflow_gate)
              [step] = Workflows.list_step_runs(state.run.id)
              assert step.status == "cancelled"
              assert length(step.trace_events) == 5
              {%{}, state}
          end
        )
      after
        Enum.each(runs, fn {_mode, run} ->
          monitors =
            for {pid, _} <- Registry.lookup(Zaq.Engine.Workflows.RunRegistry, run.id),
                do: {pid, Process.monitor(pid)}

          current = Workflows.get_run!(run.id)

          if current.status in ["pending", "running", "waiting", "paused"],
            do: Workflows.cancel_run(current)

          for {pid, monitor} <- monitors do
            assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 10_000
          end
        end)
      end

      refute_received {:llm_stub_error, _}
    end
  end

  defp provider_reply(body, chunk) do
    request = MultiAgentOpenAIStub.decode_request!(body)

    if body =~ "TRACE_AGENT_EARLY_FAIL" do
      rate_limit_reply()
    else
      search_provider_reply(request, body, chunk)
    end
  end

  defp search_provider_reply(request, body, chunk) do
    case MultiAgentOpenAIStub.tool_results(request) do
      [] ->
        {200,
         MultiAgentOpenAIStub.tool_call_sse(
           "search_knowledge_base",
           %{
             query: "nestedneedle",
             lexical_terms: ["nestedneedle"],
             search_mode: "keyword",
             max_total_results: 1
           },
           model: request["model"],
           call_id: "opaque.native.root"
         )}

      results ->
        assert Enum.any?(results, fn result ->
                 result.output["ok"] == true and
                   Enum.any?(result.output["result"]["chunks"], &(&1["chunk_id"] == chunk.id))
               end)

        final_provider_reply(body, request["model"])
    end
  end

  defp final_provider_reply(body, model) do
    if body =~ "TRACE_AGENT_FAIL" do
      rate_limit_reply()
    else
      {200, MultiAgentOpenAIStub.text_sse("Nested trace answer", model)}
    end
  end

  defp rate_limit_reply do
    {429,
     Jason.encode!(%{error: %{type: "rate_limit_error", message: "Fixture provider rate limit"}})}
  end

  defp agent_workflow_runs(agent_id) do
    Map.new(
      [
        {"agent-completed", "Find nestedneedle"},
        {"agent-failed", "TRACE_AGENT_FAIL Find nestedneedle"},
        {"agent-early-failed", "TRACE_AGENT_EARLY_FAIL Find nestedneedle"}
      ],
      fn {mode, input} ->
        {:ok, workflow} =
          Workflows.create_workflow(%{
            name: "Configured #{mode}",
            nodes: [
              %{
                name: "configured_agent",
                type: "agent",
                module: inspect(RunAgent),
                params: %{agent_id: agent_id, input: input},
                index: 0
              }
            ],
            edges: []
          })

        {:ok, run} =
          Workflows.create_run(workflow, %{
            "request" => nil,
            "actor" => %{kind: :system, subject: "nested-agent-browser-fixture"},
            "assigns" => %{}
          })

        {mode, run}
      end
    )
  end

  defp assert_agent_workflow_evidence("agent-early-failed", step, trace, children) do
    assert step.errors["reason"] == "agent_failed::provider_rate_limited"
    assert children == []
    assert ToolStep.project(trace) == []
    refute Map.has_key?(step.results, "output")
  end

  defp assert_agent_workflow_evidence(mode, step, trace, children) do
    assert [%{"id" => "opaque.native.root", "state" => "succeeded"}] = ToolStep.project(trace)
    assert length(children) >= 3
    assert Enum.all?(children, &(&1["outcome"] == "succeeded"))

    if mode == "agent-failed" do
      assert step.errors["reason"] == "agent_failed::provider_rate_limited"
      refute Map.has_key?(step.results, "output")
      refute Map.has_key?(step.results, "__cascade__")
    else
      assert step.results["output"] == "Nested trace answer"
    end
  end

  defp restore_runtime_dependencies do
    keys = [:chat_live_node_router_module, :pipeline_hooks_module]
    previous = Map.new(keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(keys, &Application.delete_env(:zaq, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)
  end
end
