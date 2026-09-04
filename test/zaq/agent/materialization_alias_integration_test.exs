defmodule Zaq.Agent.MaterializationAliasIntegrationTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent, as: AgentContext
  alias Zaq.Agent.{Executor, ServerManager}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Materialization
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  defmodule MaterializationRouter do
    @moduledoc false

    def dispatch(%Event{opts: opts} = event) do
      case Keyword.get(opts, :action) do
        :data_source_search_files -> search_documents(event)
        :data_source_download_document -> download_document(event)
        _other -> event
      end
    end

    defp search_documents(%Event{actor: %{test_pid: test_pid}} = event) do
      {:ok, first_handle} =
        Materialization.issue("data_source_document", %{
          "provider" => "google_drive",
          "file_id" => "alpha.txt"
        })

      {:ok, second_handle} =
        Materialization.issue("data_source_document", %{
          "provider" => "google_drive",
          "file_id" => "beta.txt"
        })

      send(test_pid, {:search_dispatched, [first_handle, second_handle]})

      %{
        event
        | response:
            {:ok,
             %{
               records: [
                 %Record{
                   id: "alpha.txt",
                   kind: :file,
                   name: "alpha.txt",
                   materialization_handle: first_handle
                 }
                 |> seal!(),
                 %Record{
                   id: "beta.txt",
                   kind: :file,
                   name: "beta.txt",
                   materialization_handle: second_handle
                 }
                 |> seal!()
               ]
             }}
      }
    end

    defp download_document(%Event{actor: %{test_pid: test_pid}, request: request} = event) do
      %{provider: "google_drive", params: %{"file_id" => file_id}} = request
      send(test_pid, {:materialized, file_id, Keyword.get(event.opts, :materialization_verified)})

      %{
        event
        | response:
            {:ok,
             %{
               record:
                 %Record{
                   id: file_id,
                   kind: :file,
                   name: file_id,
                   content: "content for #{file_id}"
                 }
                 |> seal!()
             }}
      }
    end

    defp seal!(%Record{} = record) do
      {:ok, sealed} = Provenance.seal(record)
      sealed
    end
  end

  test "short materialization aliases round-trip through Factory callbacks and materialize" do
    test_pid = self()
    {:ok, state} = Elixir.Agent.start_link(fn -> %{aliases: []} end)

    handler = fn _conn, body ->
      cond do
        not MultiAgentOpenAIStub.tool_result?(body) ->
          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "search_documents",
             %{provider: "google_drive", query: "project files"},
             model: "gpt-4.1-mini"
           )}

        body =~ "alpha.txt" and body =~ "beta.txt" and body =~ "mat_" and
            not String.contains?(body, "content for alpha.txt") ->
          aliases = body |> materialization_aliases() |> Enum.uniq()
          Elixir.Agent.update(state, &Map.put(&1, :aliases, aliases))
          send(test_pid, {:llm_saw_search_result, body, aliases})

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "download_document",
             %{materialization_handle: hd(aliases)},
             model: "gpt-4.1-mini"
           )}

        String.contains?(body, "content for alpha.txt") and
            not String.contains?(body, "content for beta.txt") ->
          %{aliases: aliases} = Elixir.Agent.get(state, & &1)

          {200,
           MultiAgentOpenAIStub.tool_call_sse(
             "download_document",
             %{materialization_handle: List.last(aliases)},
             model: "gpt-4.1-mini"
           )}

        String.contains?(body, "content for alpha.txt") and
            String.contains?(body, "content for beta.txt") ->
          send(test_pid, {:llm_saw_materialized_results, body})

          {200,
           MultiAgentOpenAIStub.text_sse("Both documents were materialized.", "gpt-4.1-mini")}

        true ->
          raise "unmatched LLM request body: #{String.slice(body, 0, 2_000)}"
      end
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Alias Integration Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      AgentContext.create_agent(%{
        name: "Alias Integration Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Search documents, then download the matching handles.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["data_source.search_documents", "data_source.download_document"],
        conversation_enabled: false,
        active: true,
        model_max_context_tokens: 128_000,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    incoming = %Incoming{
      content: "Find and materialize the project files",
      channel_id: "bo-test",
      provider: :web,
      metadata: %{session_id: "alias-regression-#{System.unique_integer([:positive])}"}
    }

    event = Event.new(%{}, :agent, actor: %{test_pid: test_pid})

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(configured_agent.id),
        event: event,
        node_router: MaterializationRouter
      )

    assert outgoing.metadata.error == false
    assert outgoing.body =~ "Both documents were materialized"

    assert_received {:search_dispatched, signed_handles}
    assert_received {:llm_saw_search_result, search_body, aliases}

    assert length(aliases) == 2
    assert Enum.all?(aliases, &String.starts_with?(&1, "mat_"))
    refute Enum.at(aliases, 0) == Enum.at(aliases, 1)

    Enum.each(signed_handles, fn signed_handle ->
      refute String.contains?(search_body, signed_handle)
    end)

    assert receive_materialized([]) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
             "alpha.txt",
             "beta.txt"
           ]

    assert_received {:llm_saw_materialized_results, materialized_body}

    assert String.contains?(materialized_body, "content for alpha.txt")
    assert String.contains?(materialized_body, "content for beta.txt")
  end

  defp materialization_aliases(body),
    do: Regex.scan(~r/mat_[A-Za-z0-9_-]+/, body) |> List.flatten()

  defp receive_materialized(acc) do
    receive do
      {:materialized, file_id, verified?} -> receive_materialized([{file_id, verified?} | acc])
    after
      0 -> acc
    end
  end
end
