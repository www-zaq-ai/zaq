defmodule Zaq.Agent.Tools.GoogleDrive.SearchDocumentsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.GoogleDrive.SearchDocuments
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{records: [%{"id" => "d1", "name" => "Doc"}]}}
      }
    end
  end

  defmodule OkPayloadNoRecordsNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:ok, %{foo: "bar"}}}
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedResponseNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :not_a_tuple}
  end

  test "dispatches datasource search_files action and returns metadata records" do
    assert {:ok, %{records: [%{"id" => "d1", "name" => "Doc"}], count: 1}} =
             SearchDocuments.run(%{provider: "google_drive", query: "invoice"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_search_files, %{"query" => "invoice"}}
  end

  test "passes optional path and config_id" do
    assert {:ok, _} =
             SearchDocuments.run(
               %{provider: "google_drive", query: "invoice", path: "/finance", config_id: "2"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_search_files,
                     %{"query" => "invoice", "path" => "/finance", "config_id" => "2"}}
  end

  test "returns ok payload unchanged when response has no records key" do
    assert {:ok, %{foo: "bar"}} =
             SearchDocuments.run(%{provider: "google_drive", query: "invoice"}, %{
               node_router: OkPayloadNoRecordsNodeRouter
             })
  end

  test "formats datasource error reason into user-facing error message" do
    assert {:error, message} =
             SearchDocuments.run(%{provider: "google_drive", query: "invoice"}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source document search failed: :timeout"
  end

  test "returns unexpected response error when router response shape is unsupported" do
    assert {:error, message} =
             SearchDocuments.run(%{provider: "google_drive", query: "invoice"}, %{
               node_router: UnexpectedResponseNodeRouter
             })

    assert message == "Unexpected data source response: :not_a_tuple"
  end
end
