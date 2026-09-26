defmodule Zaq.Ingestion.ApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.Api
  alias Zaq.Ingestion.Document

  defmodule StubIngestion do
    def list_document_sources(query), do: [{:source, query}]

    def sync_data_source_permission_projection(provider, config_id, affected_file_ids, context) do
      send(self(), {:sync_permission_projection, provider, config_id, affected_file_ids, context})
      :ok
    end
  end

  defmodule StubChunkLanguages do
    def list, do: ["english", "french"]
  end

  defmodule StubDocumentProcessor do
    def limit_chunks(chunks) do
      send(self(), {:limit_chunks, chunks})
      Enum.take(chunks, 1)
    end

    def query_extraction("failure", access_opts) do
      send(self(), {:query_extraction, "failure", access_opts})
      {:error, :search_failed}
    end

    def query_extraction(query, access_opts) do
      send(self(), {:query_extraction, query, access_opts})
      {:ok, [%{content: "matched result"}]}
    end
  end

  defp handle(request, action) do
    request
    |> Event.new(:ingestion, opts: [action: action])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  test "enriches records through the ingestion boundary" do
    record = %Record{id: "api-enrichment-missing", kind: :file}
    event = Event.new(%{records: [record]}, :ingestion, opts: [action: :enrich_records])
    result = Api.handle_event(event, :enrich_records, nil)

    assert result.response ==
             {:ok,
              %{
                "api-enrichment-missing" => %{
                  document_id: nil,
                  indexed?: false,
                  ingested_at: nil,
                  permissions_count: 0,
                  watch_status: nil,
                  watch_error: nil,
                  public?: false
                }
              }}

    assert result.request == event.request
    assert result.next_hop == event.next_hop
    assert result.opts == event.opts
  end

  test "lists document sources through the ingestion boundary" do
    event =
      Event.new(%{query: "handbook"}, :ingestion,
        opts: [action: :list_document_sources, ingestion_module: StubIngestion]
      )

    result = Api.handle_event(event, :list_document_sources, nil)

    assert result.response == [{:source, "handbook"}]
  end

  test "lists chunk languages through the configured inventory" do
    event =
      Event.new(%{}, :ingestion,
        opts: [action: :list_chunk_languages, chunk_languages: StubChunkLanguages]
      )

    result = Api.handle_event(event, :list_chunk_languages, nil)

    assert result.response == {:ok, ["english", "french"]}
    assert result.request == event.request
    assert result.opts == event.opts
  end

  test "limits knowledge results through the configured document processor" do
    first = %{content: "first"}
    second = %{content: "second"}
    request = %{chunks: [first, second]}

    event =
      Event.new(request, :ingestion,
        opts: [action: :limit_knowledge_results, document_processor: StubDocumentProcessor]
      )

    result = Api.handle_event(event, :limit_knowledge_results, nil)

    assert result.response == {:ok, [first]}
    assert_received {:limit_chunks, [^first, ^second]}
    assert result.request == event.request
    assert result.opts == event.opts
  end

  test "rejects malformed knowledge-result chunks without invoking the processor" do
    event =
      Event.new(%{chunks: :invalid}, :ingestion,
        opts: [action: :limit_knowledge_results, document_processor: StubDocumentProcessor]
      )

    assert Api.handle_event(event, :limit_knowledge_results, nil).response ==
             {:error, {:unsupported_action, :limit_knowledge_results}}

    refute_received {:limit_chunks, _chunks}
  end

  test "searches the knowledge base and preserves the processor result" do
    request = %{
      query: "handbook",
      access_opts: [person_id: 7, source_filter: ["manual"]]
    }

    event =
      Event.new(request, :ingestion,
        opts: [action: :search_knowledge_base, document_processor: StubDocumentProcessor]
      )

    result = Api.handle_event(event, :search_knowledge_base, nil)

    assert result.response == {:ok, [%{content: "matched result"}]}
    assert_received {:query_extraction, "handbook", [person_id: 7, source_filter: ["manual"]]}
    assert result.request == event.request
    assert result.opts == event.opts
  end

  test "passes through knowledge search errors" do
    request = %{query: "failure", access_opts: []}

    event =
      Event.new(request, :ingestion,
        opts: [action: :search_knowledge_base, document_processor: StubDocumentProcessor]
      )

    result = Api.handle_event(event, :search_knowledge_base, nil)

    assert result.response == {:error, :search_failed}
    assert_received {:query_extraction, "failure", []}
  end

  test "rejects malformed knowledge search inputs without invoking the processor" do
    for request <- [
          %{query: :invalid, access_opts: []},
          %{query: "handbook", access_opts: :invalid}
        ] do
      event =
        Event.new(request, :ingestion,
          opts: [action: :search_knowledge_base, document_processor: StubDocumentProcessor]
        )

      assert Api.handle_event(event, :search_knowledge_base, nil).response ==
               {:error, {:unsupported_action, :search_knowledge_base}}
    end

    refute_received {:query_extraction, _, _}
  end

  test "rejects malformed document source queries" do
    event = Event.new(%{query: nil}, :ingestion, opts: [action: :list_document_sources])

    assert Api.handle_event(event, :list_document_sources, nil).response ==
             {:error, {:unsupported_action, :list_document_sources}}
  end

  test "loads stored extracted Markdown through the ingestion boundary only for an authorized actor" do
    {:ok, _document} =
      Document.create(%{
        source: "data_source/disk/123/extracted.md",
        content: "# Extracted\n\nContenu français",
        metadata: %{"ingestion" => %{"detected_languages" => ["french"]}}
      })

    request = %{source: "data_source/disk/123/extracted.md"}

    for actor <- [%{}, %{person_id: nil}, %{user_id: 3, skip_permissions: false}] do
      event = Event.new(request, :ingestion, actor: actor)

      assert Api.handle_event(event, :get_ingestion_details, nil).response ==
               {:error, :unauthorized}
    end

    event = Event.new(request, :ingestion, actor: %{user_id: 3, skip_permissions: true})

    assert {:ok, %{content: "# Extracted\n\nContenu français", summary: summary}} =
             Api.handle_event(event, :get_ingestion_details, nil).response

    assert summary["detected_languages"] == ["french"]

    assert Api.handle_event(
             Event.new(%{source: "data_source/disk/123/missing.md"}, :ingestion,
               actor: %{user_id: 3, skip_permissions: true}
             ),
             :get_ingestion_details,
             nil
           ).response == {:error, :not_found}
  end

  test "forwards trusted context for bridge-triggered permission projection sync" do
    actor = %{person_id: 7}
    event_opts = [ingestion_module: StubIngestion, skip_permissions: true]

    event =
      Event.new(
        %{provider: "disk", config_id: 12, affected_file_ids: ["folder-1", "file-1"]},
        :ingestion,
        actor: actor,
        opts: event_opts
      )

    assert :ok =
             Api.handle_event(event, :sync_data_source_permission_projection, nil).response

    assert_received {:sync_permission_projection, "disk", 12, ["folder-1", "file-1"], context}
    assert context.actor == actor
    assert context.skip_permissions == true
  end

  describe "retired storage actions" do
    test "document CRUD and volume actions are no longer served by ingestion" do
      actions = [
        :describe_document,
        :list_documents,
        :materialize_document,
        :persist_document,
        :update_document,
        :delete_document,
        :list_document_grants,
        :search_documents,
        :volume_stats
      ]

      for action <- actions do
        assert handle(%{}, action) == {:error, {:unsupported_action, action}}
      end
    end

    test "the retired :materialize_record action fails loudly rather than silently" do
      assert handle(%{file_id: "archives/guide.md"}, :materialize_record) ==
               {:error, {:unsupported_action, :materialize_record}}
    end
  end
end
