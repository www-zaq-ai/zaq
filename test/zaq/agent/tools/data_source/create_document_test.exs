defmodule Zaq.Agent.Tools.DataSource.CreateDocumentTest do
  # async: false — the disk provider tests override :zaq, Zaq.Ingestion globally
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Tools.DataSource.CreateDocument
  alias Zaq.Event
  alias Zaq.Ingestion.FileExplorer

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

    assert message == "Unexpected channel response: :ok"
  end

  describe "disk provider" do
    @test_base "test/tmp/create_document"

    defmodule LocalNodeRouter do
      @moduledoc false
      alias Zaq.Channels.Api

      def dispatch(%Event{} = event),
        do: Api.handle_event(event, :data_source_create_file, nil)
    end

    setup do
      File.rm_rf!(@test_base)
      File.mkdir_p!(@test_base)

      original = Application.get_env(:zaq, Zaq.Ingestion)
      Application.put_env(:zaq, Zaq.Ingestion, base_path: @test_base)

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
        File.rm_rf!(@test_base)
      end)

      :ok
    end

    test "writes to the local volume through the real disk bridge" do
      assert {:ok, %{status: "created", record: record}} =
               CreateDocument.run(
                 %{provider: "disk", name: "Summary", content: "hello", mime_type: "text/plain"},
                 %{node_router: LocalNodeRouter}
               )

      assert record.name == "Summary.txt"
      assert record.path == "generated/Summary.txt"

      assert {:ok, abs_path} = FileExplorer.resolve_path("generated/Summary.txt")
      assert File.read!(abs_path) == "hello"
    end
  end
end
