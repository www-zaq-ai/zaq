defmodule Zaq.Agent.Tools.DataSource.DeleteDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.DeleteDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{
          request: %{record: %Record{} = record},
          opts: opts,
          actor: actor
        }) do
      send(self(), {:dispatch, opts[:action], record, actor, opts})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "deleted", result: %{"id" => "f1"}}}
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

  test "dispatches datasource delete_file action with a loaded record" do
    assert {:ok, %{status: "deleted", result: %{"id" => "f1"}}} =
             DeleteDocument.run(
               %{record: record()},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_delete_file, %Record{id: "f1"}, nil, _opts}
  end

  test "passes actor with the record dispatch" do
    assert {:ok, _} =
             DeleteDocument.run(
               %{record: record()},
               %{node_router: StubNodeRouter, actor: %{provider: "bo"}}
             )

    assert_received {:dispatch, :data_source_delete_file, %Record{id: "f1"}, %{provider: "bo"},
                     _opts}
  end

  test "passes event opts to the channels event" do
    assert {:ok, _} =
             DeleteDocument.run(%{record: record()}, %{
               node_router: StubNodeRouter,
               event_opts: [data_source_bridge_module: StubBridge]
             })

    assert_received {:dispatch, :data_source_delete_file, %Record{id: "f1"}, nil, opts}
    assert opts[:data_source_bridge_module] == StubBridge
  end

  test "rejects non-record input" do
    assert {:error, {:invalid_input, :expected_record}} =
             DeleteDocument.run(%{record: %{id: "f1"}}, %{})

    assert {:error, {:invalid_input, :expected_record}} =
             DeleteDocument.run(%{provider: "google_drive", document_id: "f1"}, %{})
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             DeleteDocument.run(%{record: record()}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source document deletion failed: :timeout"
  end

  test "returns unexpected response error" do
    assert {:error, message} =
             DeleteDocument.run(%{record: record()}, %{
               node_router: UnexpectedNodeRouter
             })

    assert message == "Unexpected data source response: :ok"
  end
end
