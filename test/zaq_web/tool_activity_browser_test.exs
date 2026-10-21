defmodule ZaqWeb.ToolActivityBrowserTest do
  use ZaqWeb.ConnCase, async: false
  @moduletag :real_browser

  import Ecto.Query
  import Mox
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.{ServerManager, StreamEvents}
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Repo
  alias Zaq.TestSupport.{HistoryBrowser, MultiAgentOpenAIStub, OpenAIStub}

  setup :verify_on_exit!

  defmodule QuietStatus do
    def broadcast(incoming, _stage, _body, _router, _opts), do: incoming
  end

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 180_000
    test "#{engine}: live tools, refresh continuity and denied history at mobile/desktop widths" do
      engine = unquote(engine)
      owner = self()
      set_mox_global()
      stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
      Zaq.DataCase.isolate_event_registry()
      restore_runtime_dependencies()
      user = user_fixture()
      other = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
      {partial, legacy, forbidden} = stored_history(user, other)
      counter = start_supervised!({Agent, fn -> 0 end})

      {server, endpoint} =
        OpenAIStub.server(
          fn _conn, body ->
            request = Jason.decode!(body)
            turn = Agent.get_and_update(counter, &{rem(&1, 4), &1 + 1})

            if turn < 3 do
              arguments =
                if turn == 1,
                  do: %{value: "PRIVATE_TOOL_ARGUMENT", amount: 3},
                  else: %{value: 2, amount: 3}

              {200,
               MultiAgentOpenAIStub.tool_call_sse("add", arguments,
                 model: request["model"],
                 call_id: "browser-call-#{turn}"
               )}
            else
              send(owner, {:tool_final_wait, self()})

              receive do
                :release_tool_final ->
                  {200, MultiAgentOpenAIStub.text_sse("Tool continuity answer", request["model"])}
              after
                30_000 -> raise "Browser did not release final model response"
              end
            end
          end,
          owner
        )

      start_supervised!(server)

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "test-key"})

      {:ok, agent} =
        Zaq.Agent.create_agent(%{
          name: "Tool continuity #{engine}",
          description: "",
          job: "Answer briefly.",
          model: "gpt-4.1-mini",
          model_max_context_tokens: 20_000,
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: ["arithmetic.add"],
          conversation_enabled: true,
          active: true,
          advanced_options: %{"stream" => true}
        })

      on_exit(fn -> ServerManager.stop_server(agent) end)

      HistoryBrowser.run!(
        %{
          runner: "test/e2e/support/tool-activity-browser.cjs",
          screenshot_dir:
            System.get_env("TOOL_ACTIVITY_SCREENSHOTS") ||
              Path.join(System.tmp_dir!(), "opencode"),
          engine: engine,
          username: user.username,
          agent_id: agent.id,
          partial_id: partial.id,
          legacy_id: legacy.id,
          forbidden_id: forbidden.id
        },
        fn
          "tools-visible", state ->
            assert_receive {:tool_final_wait, worker}, 15_000
            send(worker, :release_tool_final)
            {%{}, state}

          "saved", state ->
            answer =
              Repo.one!(
                from m in Message,
                  join: c in Conversation,
                  on: c.id == m.conversation_id,
                  where:
                    c.user_id == ^user.id and m.role == "assistant" and
                      m.content == "Tool continuity answer",
                  order_by: [desc: m.inserted_at],
                  limit: 1
              )

            {%{
               conversation_id: answer.conversation_id,
               answer_id: answer.id,
               steps: ToolStep.project(answer.trace)
             }, Map.put(state, :conversation_id, answer.conversation_id)}

          "revoke", state ->
            {:ok, _} =
              Conversations.update_conversation(
                Conversations.get_conversation(state.conversation_id),
                %{user_id: other.id}
              )

            {%{}, state}
        end
      )

      refute_received {:llm_stub_error, _}
    end
  end

  defp restore_runtime_dependencies do
    keys = [:chat_live_node_router_module, :pipeline_executor_module, :pipeline_hooks_module]
    previous = Map.new(keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(keys, &Application.delete_env(:zaq, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)
  end

  defp stored_history(user, other) do
    {:ok, partial} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        user_id: user.id,
        title: "Partial history"
      })

    incoming =
      Incoming.new(%{
        content: "Interrupted question",
        provider: :web,
        channel_id: "bo",
        author_id: to_string(user.id),
        metadata: %{user_id: user.id, conversation_id: partial.id, request_id: "partial"}
      })
      |> CommunicationBridge.put_conversation_identity()

    events = [
      %{
        kind: :tool_completed,
        at_ms: 1,
        tool_call_id: "known",
        tool_name: "search",
        data: %{result: {:ok, "private"}}
      },
      %{
        kind: :tool_started,
        at_ms: 2,
        tool_call_id: "outstanding",
        tool_name: "search",
        data: %{}
      },
      %{kind: :request_failed, at_ms: 3, data: %{error: :interrupted}}
    ]

    {:error, :interrupted, reduced} =
      StreamEvents.consume(events, incoming, status_module: QuietStatus)

    {:ok, _} =
      Zaq.ConversationLifecycleFixtures.complete_exchange(
        incoming,
        %{answer: "Partial browser answer", trace: reduced.trace, tool_calls: reduced.tool_calls},
        actor: %{kind: :bo_user, subject: "bo:#{user.id}", user_id: user.id}
      )

    {:ok, legacy} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        user_id: user.id,
        title: "Legacy history"
      })

    {:ok, _} =
      Conversations.add_message(legacy, %{
        role: "assistant",
        content: "Legacy browser answer",
        trace: [%{"id" => "legacy-event", "type" => "tool_call", "status" => "completed"}]
      })

    {:ok, forbidden} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        user_id: other.id,
        title: "Forbidden history"
      })

    {:ok, _} =
      Conversations.add_message(forbidden, %{role: "assistant", content: "FORBIDDEN_HISTORY"})

    {partial, legacy, forbidden}
  end
end
