defmodule Zaq.Agent.Tools.CreateSheetTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.CreateSheet
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "created", record: %{id: "s1", kind: :spreadsheet}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  test "dispatches datasource sheet create action with required params only" do
    assert {:ok, %{status: "created", record: %{id: "s1", kind: :spreadsheet}}} =
             CreateSheet.run(%{provider: "google_drive", title: "Roadmap"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_sheet_create, %{"title" => "Roadmap"}}
  end

  test "includes optional config_id in datasource create request" do
    assert {:ok, _} =
             CreateSheet.run(
               %{provider: "google_drive", title: "Roadmap", config_id: "12"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_sheet_create,
                     %{"title" => "Roadmap", "config_id" => "12"}}
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             CreateSheet.run(%{provider: "google_drive", title: "Roadmap"}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source sheet creation failed: :timeout"
  end

  test "returns unexpected response error" do
    assert {:error, message} =
             CreateSheet.run(%{provider: "google_drive", title: "Roadmap"}, %{
               node_router: UnexpectedNodeRouter
             })

    assert message == "Unexpected data source response: :ok"
  end
end
