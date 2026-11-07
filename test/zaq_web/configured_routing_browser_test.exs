defmodule ZaqWeb.ConfiguredRoutingBrowserTest do
  @moduledoc "Configured-only routing journey over the real BO, Engine and native Agent runtime."
  use ZaqWeb.ConnCase, async: false

  @moduletag :real_browser
  @moduletag :paradedb

  import Ecto.Query
  import Mox
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem
  alias Zaq.TestSupport.{HistoryBrowser, MultiAgentOpenAIStub, OpenAIStub}
  alias Zaq.UserPortal.ClientMock

  setup :verify_on_exit!

  for engine <- ~w(chromium firefox webkit) do
    @tag timeout: 180_000
    @tag browser_engine: engine
    test "#{engine}: configured search, inherited selection and no built-in fallback" do
      owner = self()
      engine = unquote(engine)
      set_mox_global()
      stub(Zaq.NodeRouterMock, :find_node, fn _ -> node() end)
      Zaq.DataCase.isolate_event_registry()
      Chunk.create_table(1536)
      ChunkLanguages.invalidate()
      on_exit(fn -> ChunkLanguages.invalidate() end)

      user = user_fixture()
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
      {:ok, document} = Document.upsert(%{source: "routing-#{engine}/guide.md"})
      {:ok, _} = Permissions.grant_public(document)

      {:ok, chunk} =
        Chunk.create(%{
          document_id: document.id,
          chunk_index: 0,
          content: "routingneedle evidence for configured-only answers",
          language: "simple"
        })

      {server, endpoint} =
        OpenAIStub.server(fn _conn, body -> provider_reply(body, chunk, owner) end, owner)

      start_supervised!(server)

      credential =
        ai_credential_fixture(%{provider: "openai", endpoint: endpoint, api_key: "fixture-key"})

      {:ok, agent} =
        Zaq.Agent.create_agent(%{
          name: "Routing browser #{engine}",
          job: "Search for the requested evidence and answer briefly.",
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

      HistoryBrowser.run!(
        %{
          runner: "test/e2e/support/configured-routing-browser.cjs",
          engine: engine,
          username: user.username,
          agent_id: agent.id,
          agent_name: agent.name
        },
        fn
          "inherited-answer", state ->
            assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id
            assert_receive {:routing_search_completed, id}, 5_000
            assert id == chunk.id
            assert_answer_count(user.id, 1)
            {%{}, state}

          "global-clear", state ->
            assert IncomingMessageRouting.get_rule(%{}) == nil

            user
            |> Accounts.User.portal_consent_changeset("declined")
            |> Repo.update!()

            assert {:ok, bootstrap_agent} =
                     Zaq.Agent.create_agent(%{
                       name: "ZAQ Assistant",
                       job: "Preserve this job",
                       model: "gpt-4.1-mini",
                       credential_id: credential.id,
                       conversation_enabled: false
                     })

            stub(ClientMock, :fetch_onboarding, fn _ ->
              {:ok, Zaq.PortalStubs.onboarding_message()}
            end)

            expect(ClientMock, :onboard_user, 1, fn email ->
              assert email == user.email
              {:ok, %{litellm_api_key: "sk-browser-claim"}}
            end)

            {%{}, Map.put(state, :bootstrap_agent, bootstrap_agent)}

          "explicit-global-none", state ->
            assert %{routing_mode: :none, configured_agent_id: nil} =
                     rule = IncomingMessageRouting.get_rule(%{})

            {%{}, Map.put(state, :none_rule, rule)}

          "activation-failed", state ->
            assert Accounts.get_user!(user.id).portal_consent == "declined"
            assert IncomingMessageRouting.get_rule(%{}) == state.none_rule
            claimed = ZaqSystem.get_ai_provider_credential_by_name("ZAQ Router")

            assert claimed.metadata["user_portal_claim"] == %{
                     "version" => 1,
                     "email" => user.email
                   }

            assert {:ok, _} =
                     Zaq.Agent.update_agent(state.bootstrap_agent, %{conversation_enabled: true})

            {%{}, Map.put(state, :claimed_credential_id, claimed.id)}

          "activation-recovered", state ->
            assert Accounts.get_user!(user.id).portal_consent == "accepted"
            assert IncomingMessageRouting.get_rule(%{}) == state.none_rule

            assert ZaqSystem.get_ai_provider_credential_by_name("ZAQ Router").id ==
                     state.claimed_credential_id

            {%{}, state}

          "explicit-answer", state ->
            assert_receive {:routing_search_completed, id}, 5_000
            assert id == chunk.id
            assert_answer_count(user.id, 2)
            {%{}, state}

          "delete-selected", state ->
            assert {:ok, _} = Zaq.Agent.delete_agent(agent)
            {%{}, state}

          "deleted-selection", state ->
            refute_received {:routing_model_request, _}
            assert_answer_count(user.id, 2)
            {%{}, state}

          "no-fallback", state ->
            refute_received {:routing_model_request, _}
            assert_answer_count(user.id, 2)
            {%{}, state}
        end
      )

      refute_received {:llm_stub_error, _}
    end
  end

  defp provider_reply(body, chunk, owner) do
    request = MultiAgentOpenAIStub.decode_request!(body)
    send(owner, {:routing_model_request, request["model"]})

    case MultiAgentOpenAIStub.tool_results(request) do
      [] ->
        {200,
         MultiAgentOpenAIStub.tool_call_sse(
           "search_knowledge_base",
           %{
             query: "routingneedle",
             lexical_terms: ["routingneedle"],
             search_mode: "keyword",
             max_total_results: 1
           },
           model: "gpt-4.1-mini"
         )}

      results ->
        assert Enum.any?(results, fn result ->
                 result.output["ok"] == true and
                   Enum.any?(result.output["result"]["chunks"], &(&1["chunk_id"] == chunk.id))
               end)

        send(owner, {:routing_search_completed, chunk.id})

        {200,
         MultiAgentOpenAIStub.text_sse("Configured routing evidence delivered.", "gpt-4.1-mini")}
    end
  end

  defp assert_answer_count(user_id, expected) do
    assert Repo.aggregate(
             from(m in Message,
               join: c in Conversation,
               on: c.id == m.conversation_id,
               where:
                 c.user_id == ^user_id and m.role == "assistant" and
                   m.content == "Configured routing evidence delivered."
             ),
             :count
           ) == expected

    drain_model_requests()
  end

  defp drain_model_requests do
    receive do
      {:routing_model_request, _} -> drain_model_requests()
    after
      0 -> :ok
    end
  end
end
