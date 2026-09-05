defmodule Zaq.Ingestion.ApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.Api

  defmodule StubIngestion do
    def list_document_sources(query), do: [{:source, query}]
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

  test "rejects malformed document source queries" do
    event = Event.new(%{query: nil}, :ingestion, opts: [action: :list_document_sources])

    assert Api.handle_event(event, :list_document_sources, nil).response ==
             {:error, {:unsupported_action, :list_document_sources}}
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
