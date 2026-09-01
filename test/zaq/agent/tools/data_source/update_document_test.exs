defmodule Zaq.Agent.Tools.DataSource.UpdateDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.UpdateDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{
          request: %{record: %Record{} = record, params: params},
          opts: opts,
          actor: actor
        }) do
      send(self(), {:dispatch, opts[:action], record, params, actor, opts})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "updated", record: %{"id" => "f1"}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  defp record(attrs \\ %{}) do
    %Record{
      id: "f1",
      kind: :file,
      attributes: %{"provider" => "google_drive", "config_id" => "12"}
    }
    |> Map.merge(attrs)
  end

  test "dispatches datasource update_file action with a loaded record" do
    assert {:ok, %{status: "updated", record: %{"id" => "f1"}}} =
             UpdateDocument.run(
               %{record: record(), changes: %{name: "Renamed"}},
               %{
                 node_router: StubNodeRouter
               }
             )

    assert_received {:dispatch, :data_source_update_file, %Record{id: "f1"},
                     %{"name" => "Renamed"}, nil, _opts}
  end

  test "passes optional params when present" do
    assert {:ok, _} =
             UpdateDocument.run(
               %{
                 record: record(),
                 changes: %{
                   content: "hello",
                   path: "/docs",
                   parent_id: "p1",
                   mime_type: "text/plain"
                 }
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_file, %Record{id: "f1"},
                     %{
                       "content" => "hello",
                       "path" => "/docs",
                       "parent_id" => "p1",
                       "mime_type" => "text/plain"
                     }, nil, _opts}
  end

  test "ignores top-level mutation fields when changes is present" do
    assert {:ok, _} =
             UpdateDocument.run(
               %{
                 record: record(),
                 name: "Ignored top-level name",
                 changes: %{"name" => "Renamed", path: "/docs"}
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_file, %Record{id: "f1"},
                     %{"name" => "Renamed", "path" => "/docs"}, nil, _opts}
  end

  test "passes actor with the record dispatch" do
    assert {:ok, _} =
             UpdateDocument.run(
               %{record: record(), changes: %{name: "Renamed"}},
               %{node_router: StubNodeRouter, actor: %{provider: "bo"}}
             )

    assert_received {:dispatch, :data_source_update_file, %Record{id: "f1"},
                     %{"name" => "Renamed"}, %{provider: "bo"}, _opts}
  end

  test "passes event opts to the channels event" do
    assert {:ok, _} =
             UpdateDocument.run(%{record: record(), changes: %{name: "Renamed"}}, %{
               node_router: StubNodeRouter,
               event_opts: [data_source_bridge_module: StubBridge]
             })

    assert_received {:dispatch, :data_source_update_file, %Record{id: "f1"},
                     %{"name" => "Renamed"}, nil, opts}

    assert opts[:data_source_bridge_module] == StubBridge
  end

  test "rejects non-record input" do
    assert {:error, {:invalid_input, :expected_record}} =
             UpdateDocument.run(%{record: %{id: "f1"}}, %{})

    assert {:error, {:invalid_input, :expected_record}} =
             UpdateDocument.run(%{provider: "google_drive", document_id: "f1"}, %{})
  end

  test "rejects missing or non-map changes" do
    assert {:error, {:invalid_input, :expected_changes}} =
             UpdateDocument.run(%{record: record(), name: "Renamed"}, %{})

    assert {:error, {:invalid_input, :expected_changes}} =
             UpdateDocument.run(%{record: record(), changes: "Renamed"}, %{})
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             UpdateDocument.run(%{record: record(), changes: %{}}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source document update failed: :timeout"
  end

  test "returns unexpected response error" do
    assert {:error, message} =
             UpdateDocument.run(%{record: record(), changes: %{}}, %{
               node_router: UnexpectedNodeRouter
             })

    assert message == "Unexpected data source response: :ok"
  end
end
