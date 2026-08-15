defmodule Zaq.Agent.Tools.DataSourceToolTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Event

  defmodule OkNodeRouter do
    def dispatch(%Event{request: request, opts: opts}) do
      send(self(), {:dispatch, opts[:action], request})
      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{"id" => "f1"}}}}
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :weird_response}
  end

  test "dispatch/5 returns ok payload by default" do
    request = %{provider: "google_drive", params: %{"file_id" => "f1"}}

    assert {:ok, %{record: %{"id" => "f1"}}} =
             DataSourceTool.dispatch(
               :data_source_get_file,
               request,
               %{node_router: OkNodeRouter},
               "Data source document request failed"
             )

    assert_received {:dispatch, :data_source_get_file, ^request}
  end

  test "dispatch/5 applies custom on_ok formatter" do
    request = %{provider: "google_drive", params: %{"query" => "invoice"}}

    assert {:ok, %{record: %{"id" => "f1"}, count: 1}} =
             DataSourceTool.dispatch(
               :data_source_search_files,
               request,
               %{node_router: OkNodeRouter},
               "Data source document search failed",
               fn payload -> {:ok, Map.put(payload, :count, 1)} end
             )
  end

  test "dispatch/5 formats error tuples" do
    assert {:error, "Data source document request failed: :timeout"} =
             DataSourceTool.dispatch(
               :data_source_get_file,
               %{provider: "google_drive", params: %{"file_id" => "f1"}},
               %{node_router: ErrorNodeRouter},
               "Data source document request failed"
             )
  end

  test "dispatch/5 formats unexpected responses" do
    assert {:error, "Unexpected data source response: :weird_response"} =
             DataSourceTool.dispatch(
               :data_source_get_file,
               %{provider: "google_drive", params: %{"file_id" => "f1"}},
               %{node_router: UnexpectedNodeRouter},
               "Data source document request failed"
             )
  end

  test "put_if_present/3 only adds non-nil values" do
    assert %{"file_id" => "f1", "config_id" => "7"} =
             %{"file_id" => "f1"}
             |> DataSourceTool.put_if_present("config_id", "7")
             |> DataSourceTool.put_if_present("path", nil)
  end

  test "put_many_if_present/2 adds only present values" do
    assert %{"file_id" => "f1", "config_id" => "7", "range" => "Sheet1!A1"} =
             %{"file_id" => "f1"}
             |> DataSourceTool.put_many_if_present([
               {"config_id", "7"},
               {"range", "Sheet1!A1"},
               {"path", nil}
             ])
  end

  test "merge_optional/3 only merges keys the params carry" do
    params = %{document_mime_type: "application/pdf", export_mime_type: nil}

    assert DataSourceTool.merge_optional(%{"file_id" => "f1"}, params, [
             :document_mime_type,
             :export_mime_type,
             :config_id
           ]) == %{"file_id" => "f1", "document_mime_type" => "application/pdf"}
  end

  test "wrap_request/2 nests the params under the provider" do
    assert DataSourceTool.wrap_request(%{"file_id" => "f1"}, "disk") ==
             %{provider: "disk", params: %{"file_id" => "f1"}}
  end
end
