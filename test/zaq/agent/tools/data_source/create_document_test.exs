defmodule Zaq.Agent.Tools.DataSource.CreateDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.CreateDocument
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "created", record: %{"id" => "f1"}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  test "dispatches datasource create_file action" do
    assert {:ok, %{status: "created", record: %{"id" => "f1"}}} =
             CreateDocument.run(%{provider: "google_drive", name: "Doc"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_create_file, %{"name" => "Doc"}}
  end

  test "passes optional params when present" do
    assert {:ok, _} =
             CreateDocument.run(
               %{
                 provider: "google_drive",
                 name: "Doc",
                 content: "hello",
                 path: "/docs",
                 parent_id: "p1",
                 parents: ["p1", "p2"],
                 mime_type: "text/plain",
                 config_id: "12"
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_create_file,
                     %{
                       "name" => "Doc",
                       "content" => "hello",
                       "path" => "/docs",
                       "parent_id" => "p1",
                       "parents" => ["p1", "p2"],
                       "mime_type" => "text/plain",
                       "config_id" => "12"
                     }}
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             CreateDocument.run(%{provider: "google_drive"}, %{node_router: ErrorNodeRouter})

    assert message == "Data source document creation failed: :timeout"
  end

  test "returns unexpected response error" do
    assert {:error, message} =
             CreateDocument.run(%{provider: "google_drive"}, %{node_router: UnexpectedNodeRouter})

    assert message == "Unexpected data source response: :ok"
  end
end
