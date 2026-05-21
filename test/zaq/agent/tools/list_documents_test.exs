defmodule Zaq.Agent.Tools.ListDocumentsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.ListDocuments
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:ok, %{records: [%{"id" => "d1"}]}}}
    end
  end

  defmodule StubNodeRouterOkPayload do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:ok, %{status: "ok", source: "gdrive"}}}
    end
  end

  defmodule StubNodeRouterError do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: {:error, :unauthorized}}
    end
  end

  defmodule StubNodeRouterTimeout do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{Event.new(%{}, :channels) | response: :timeout}
    end
  end

  test "dispatches datasource list_files action and adds count" do
    assert {:ok, %{records: [%{"id" => "d1"}], count: 1}} =
             ListDocuments.run(%{provider: "google_drive", path: "/docs"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_list_files, %{"path" => "/docs"}}
  end

  test "passes config_id when present" do
    assert {:ok, _} =
             ListDocuments.run(
               %{provider: "google_drive", path: "/docs", config_id: "9"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_list_files, %{"path" => "/docs", "config_id" => "9"}}
  end

  test "returns ok payload unchanged when records are absent" do
    result =
      ListDocuments.run(%{provider: "google_drive", path: "/docs"}, %{
        node_router: StubNodeRouterOkPayload
      })

    assert {:ok, %{status: "ok", source: "gdrive"}} = result
    refute match?({:ok, %{count: _}}, result)
  end

  test "formats explicit errors from the dispatcher" do
    assert {:error, message} =
             ListDocuments.run(%{provider: "google_drive", path: "/docs"}, %{
               node_router: StubNodeRouterError
             })

    assert message == "Data source document listing failed: :unauthorized"
  end

  test "formats unexpected dispatcher responses" do
    assert {:error, message} =
             ListDocuments.run(%{provider: "google_drive", path: "/docs"}, %{
               node_router: StubNodeRouterTimeout
             })

    assert message == "Unexpected data source response: :timeout"
  end
end
