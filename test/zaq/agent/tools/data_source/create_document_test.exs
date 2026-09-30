defmodule Zaq.Agent.Tools.DataSource.CreateDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.CreateDocument
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{
          request: %{provider: "google_drive", params: params},
          opts: opts,
          actor: actor
        }) do
      send(self(), {:dispatch, opts[:action], params, actor, opts})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{status: "created", record: %{"id" => "f1"}}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule CanonicalNodeRouter do
    import ExUnit.Assertions

    def dispatch(%Event{request: %{provider: provider, params: params}, actor: actor} = event) do
      assert event.opts[:action] == :data_source_create_file
      assert provider == "google_drive"
      assert params["config_id"] == "12"
      assert params["parent_id"] == "selected-folder-id"
      assert params["mime_type"] == "image/png"
      assert params["content"] == <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>
      assert actor == %{id: "author-1"}

      {:ok, record} =
        Provenance.seal(%Record{id: "uploaded-1", kind: :file, name: params["name"]}, %{
          "provider" => provider,
          "config_id" => params["config_id"]
        })

      %{event | response: {:ok, %{record: record}}}
    end
  end

  defmodule FolderNodeRouter do
    import ExUnit.Assertions

    def dispatch(%Event{request: %{provider: "google_drive", params: params}} = event) do
      assert event.opts[:action] == :data_source_create_file
      assert params["config_id"] == "12"
      assert params["parent_id"] == "selected-folder-id"
      assert params["name"] == "example.org"
      assert params["kind"] == "folder"
      {:ok, folder} = Provenance.seal(%Record{id: "new-canonical-folder-id", kind: :folder})
      %{event | response: {:ok, %{record: folder}}}
    end
  end

  defmodule DiskNodeRouter do
    import ExUnit.Assertions

    def dispatch(%Event{request: %{provider: "disk", params: params}} = event) do
      assert event.opts[:action] == :data_source_create_file
      assert params["config_id"] == "24"
      assert params["path"] == "volume-a/Captures"
      assert params["kind"] == "folder"
      {:ok, folder} = Provenance.seal(%Record{id: "volume-a/Captures/example.org", kind: :folder})
      %{event | response: {:ok, %{record: folder}}}
    end
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  test "dispatches datasource create_file action" do
    assert {:ok, %{status: "created", record: %{"id" => "f1"}}} =
             CreateDocument.run(%{provider: "google_drive", name: "Doc"}, %{
               node_router: StubNodeRouter
             })

    assert_received {:dispatch, :data_source_create_file, %{"name" => "Doc"}, nil, _opts}
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
                 kind: "folder",
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
                       "kind" => "folder",
                       "config_id" => "12"
                     }, _actor, _opts}
  end

  test "decodes base64 content before dispatching" do
    encoded = Base.encode64(<<0, 255, 1>>)

    assert {:ok, _} =
             CreateDocument.run(
               %{
                 provider: "google_drive",
                 name: "image.png",
                 content: encoded,
                 encoding: "base64"
               },
               %{node_router: StubNodeRouter, actor: %{provider: "bo"}}
             )

    assert_received {:dispatch, :data_source_create_file,
                     %{"name" => "image.png", "content" => <<0, 255, 1>>}, %{provider: "bo"},
                     _opts}
  end

  test "validated action targets the selected remote config and canonical parent folder" do
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>

    assert {:ok, _} =
             Jido.Exec.run(
               CreateDocument,
               %{
                 provider: "google_drive",
                 config_id: "12",
                 parent_id: "selected-folder-id",
                 name: "page--20260929T173049Z--unique.png",
                 content: Base.encode64(png),
                 encoding: "base64",
                 mime_type: "image/png"
               },
               %{node_router: CanonicalNodeRouter, actor: %{id: "author-1"}}
             )

    assert byte_size(png) == 10
  end

  test "validated folder creation returns the remote canonical folder ID for subsequent uploads" do
    assert {:ok, %{record: %Record{id: "new-canonical-folder-id", kind: :folder}}} =
             Jido.Exec.run(
               CreateDocument,
               %{
                 provider: "google_drive",
                 config_id: "12",
                 parent_id: "selected-folder-id",
                 name: "example.org",
                 kind: "folder"
               },
               %{node_router: FolderNodeRouter}
             )
  end

  test "validated folder creation preserves the selected disk volume and nested path" do
    assert {:ok, %{record: %Record{kind: :folder}}} =
             Jido.Exec.run(
               CreateDocument,
               %{
                 provider: "disk",
                 config_id: "24",
                 path: "volume-a/Captures",
                 name: "example.org",
                 kind: "folder"
               },
               %{node_router: DiskNodeRouter}
             )
  end

  test "returns an error and does not dispatch when base64 content is invalid" do
    assert {:error, "Invalid base64 content: not valid Base64 in the standard alphabet"} =
             CreateDocument.run(
               %{
                 provider: "google_drive",
                 name: "invalid.bin",
                 content: "*",
                 encoding: "base64"
               },
               %{node_router: StubNodeRouter}
             )

    refute_received {:dispatch, _, _, _, _}
  end

  test "passes event opts to the channels event" do
    assert {:ok, _} =
             CreateDocument.run(%{provider: "google_drive", name: "Doc"}, %{
               node_router: StubNodeRouter,
               event_opts: [data_source_bridge_module: StubBridge]
             })

    assert_received {:dispatch, :data_source_create_file, %{"name" => "Doc"}, nil, opts}
    assert opts[:data_source_bridge_module] == StubBridge
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
