defmodule Zaq.Agent.Tools.DataSource.CreateDocumentTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.CreateDocument
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
