defmodule Zaq.Agent.KnowledgeNavigationFlowIntegrationTest do
  @moduledoc """
  A real configured-agent tool loop searches persisted chunks, then explicitly
  fetches neighboring IDs through NodeRouter/Ingestion with current permissions.
  Only the external LLM is a loopback HTTP stub; no internal tool is mocked.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.Executor
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}
  alias Zaq.Permissions
  alias Zaq.TestSupport.{IntegrationAgent, MultiAgentOpenAIStub, OpenAIStub}

  setup do
    Chunk.create_table(1536)
    ChunkLanguages.invalidate()
    on_exit(fn -> ChunkLanguages.invalidate() end)
    :ok
  end

  test "agent searches direct matches and explicitly fetches surrounding chunks without bypassing ACLs" do
    scope = "knowledge-navigation-#{Ecto.UUID.generate()}"
    {:ok, person} = People.create_person(%{full_name: "Reader #{scope}"})
    {:ok, document} = Document.upsert(%{source: "#{scope}/public.md"})
    {:ok, private_doc} = Document.upsert(%{source: "#{scope}/private.md"})
    {:ok, _} = Permissions.grant_public(document)
    previous = insert_chunk(document, 1, "Earlier context")
    target = insert_chunk(document, 4, "navigationneedle evidence")
    following = insert_chunk(document, 9, "Later context")
    private = insert_chunk(private_doc, 1, "Private data never disclosed")
    test_pid = self()

    fixture = %{
      previous: previous,
      target: target,
      following: following,
      private: private,
      test_pid: test_pid
    }

    {child, endpoint} = OpenAIStub.server(fn _, body -> respond(body, fixture) end, test_pid)
    start_supervised!(child)

    agent =
      IntegrationAgent.create!(
        endpoint,
        scope,
        "Search and explicitly fetch neighboring knowledge chunks.",
        ["answering.search_knowledge_base", "answering.get_knowledge_base_chunks"]
      )

    outgoing =
      Executor.run(
        %Incoming{
          content: "Find navigationneedle and fetch its surrounding context.",
          channel_id: scope,
          provider: :web,
          person: person
        },
        agent_id: to_string(agent.id),
        scope: scope
      )

    assert outgoing.metadata.error == false
    assert outgoing.body == "Retrieved the requested surrounding context."
    assert outgoing.metadata.sources == [document.source]
    assert_received {:agent_search_result, %{"count" => 1, "chunks" => [hit]}}
    assert hit["chunk_id"] == target.id
    assert hit["previous_chunk_id"] == previous.id
    assert hit["next_chunk_id"] == following.id
    assert_received {:agent_fetch_result, fetched}
    assert Enum.map(fetched["chunks"], & &1["chunk_id"]) == [previous.id, following.id]
    assert fetched["unavailable_ids"] == [private.id]
    assert fetched["sources"] == [document.source]
    refute inspect(fetched) =~ "Private data never disclosed"
    refute_received {:llm_stub_error, _}
  end

  test "agent can complete a thirteen-chunk proposal by fetching only unseen returned neighbors" do
    scope = "proposal-navigation-#{Ecto.UUID.generate()}"
    {:ok, person} = People.create_person(%{full_name: "Proposal reader #{scope}"})
    {:ok, document} = Document.upsert(%{source: "#{scope}/proposal.md"})
    {:ok, _} = Permissions.grant_public(document)

    chunks =
      Enum.map(1..13, fn index ->
        content = if index in 7..10, do: "Additional slide", else: "proposalneedle slide"
        insert_chunk(document, index, "#{content} #{index}")
      end)

    test_pid = self()

    {child, endpoint} =
      OpenAIStub.server(fn _, body -> complete_proposal(body, test_pid) end, test_pid)

    start_supervised!(child)

    agent =
      IntegrationAgent.create!(
        endpoint,
        scope,
        "Use search content directly and fetch only missing context through returned neighbor IDs.",
        ["answering.search_knowledge_base", "answering.get_knowledge_base_chunks"]
      )

    outgoing =
      Executor.run(
        %Incoming{
          content: "Read the complete proposalneedle proposal, including its missing slides.",
          channel_id: scope,
          provider: :web,
          person: person
        },
        agent_id: to_string(agent.id),
        scope: scope
      )

    assert outgoing.metadata.error == false

    assert outgoing.body ==
             "Read all thirteen proposal chunks without refetching visible content."

    assert outgoing.metadata.sources == [document.source]
    assert_received {:proposal_search, search_chunks}
    assert length(search_chunks) == 9
    assert_received {:proposal_fetch, first_ids}
    assert_received {:proposal_fetch, second_ids}
    refute_received {:proposal_fetch, _}
    search_ids = Enum.map(search_chunks, & &1["chunk_id"])
    assert Enum.sort(first_ids ++ second_ids) == Enum.map(Enum.slice(chunks, 6, 4), & &1.id)
    assert Enum.all?(first_ids ++ second_ids, &(&1 not in search_ids))
    assert length(Enum.uniq(first_ids ++ second_ids)) == 4
    refute_received {:llm_stub_error, _}
  end

  defp complete_proposal(body, test_pid) do
    request = MultiAgentOpenAIStub.decode_request!(body)
    tools = Map.new(request["tools"], &{&1["name"], &1})
    assert tools["search_knowledge_base"]["description"] =~ "usable content"
    assert tools["get_knowledge_base_chunks"]["description"] =~ "Never guess"
    results = MultiAgentOpenAIStub.tool_results(request)

    case results do
      [] ->
        {200,
         MultiAgentOpenAIStub.tool_call_sse(
           "search_knowledge_base",
           %{query: "proposalneedle", lexical_terms: ["proposalneedle"], search_mode: "keyword"},
           model: "gpt-4.1-mini",
           call_id: "proposal-search",
           fc_id: "fc_proposal_search"
         )}

      [search | _] ->
        assert Enum.all?(results, & &1.output["ok"])

        if length(results) == 1,
          do: send(test_pid, {:proposal_search, search.output["result"]["chunks"]})

        visible = Enum.flat_map(results, & &1.output["result"]["chunks"])
        seen = MapSet.new(visible, & &1["chunk_id"])

        missing =
          visible
          |> Enum.flat_map(&[&1["previous_chunk_id"], &1["next_chunk_id"]])
          |> Enum.filter(&(is_integer(&1) and not MapSet.member?(seen, &1)))
          |> Enum.uniq()
          |> Enum.sort()

        if missing == [] do
          {200,
           MultiAgentOpenAIStub.text_sse(
             "Read all thirteen proposal chunks without refetching visible content.",
             "gpt-4.1-mini"
           )}
        else
          send(test_pid, {:proposal_fetch, missing})

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "get_knowledge_base_chunks",
             %{chunk_ids: missing},
             model: "gpt-4.1-mini",
             call_id: "proposal-fetch-#{length(results)}",
             fc_id: "fc_proposal_fetch_#{length(results)}"
           )}
        end
    end
  end

  defp insert_chunk(document, index, content) do
    {:ok, chunk} =
      Chunk.create(%{
        document_id: document.id,
        chunk_index: index,
        content: content,
        section_path: ["shared section"],
        language: "simple"
      })

    chunk
  end

  defp respond(body, fixture) do
    request = MultiAgentOpenAIStub.decode_request!(body)
    advertised = Enum.map(request["tools"], & &1["name"]) |> Enum.sort()
    assert advertised == ["get_knowledge_base_chunks", "search_knowledge_base"]
    respond_to_results(MultiAgentOpenAIStub.tool_results(request), fixture)
  end

  defp respond_to_results([], _fixture) do
    {200,
     MultiAgentOpenAIStub.tool_call_sse(
       "search_knowledge_base",
       %{
         query: "navigationneedle",
         lexical_terms: ["navigationneedle"],
         search_mode: "keyword",
         max_total_results: 1
       },
       model: "gpt-4.1-mini",
       call_id: "search",
       fc_id: "fc_search"
     )}
  end

  defp respond_to_results([search], fixture) do
    assert search.output["ok"] == true
    result = search.output["result"]
    assert [%{"chunk_id" => id} = hit] = result["chunks"]
    assert id == fixture.target.id
    send(fixture.test_pid, {:agent_search_result, result})

    {200,
     MultiAgentOpenAIStub.tool_call_sse(
       "get_knowledge_base_chunks",
       %{
         chunk_ids: [hit["previous_chunk_id"], hit["next_chunk_id"], fixture.private.id]
       },
       model: "gpt-4.1-mini",
       call_id: "fetch",
       fc_id: "fc_fetch"
     )}
  end

  defp respond_to_results([_search, fetch], fixture) do
    assert fetch.output["ok"] == true
    send(fixture.test_pid, {:agent_fetch_result, fetch.output["result"]})

    {200,
     MultiAgentOpenAIStub.text_sse("Retrieved the requested surrounding context.", "gpt-4.1-mini")}
  end
end
