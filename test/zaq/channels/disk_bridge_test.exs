defmodule Zaq.Channels.DiskBridgeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.DiskBridge
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event

  defmodule EchoRouter do
    def dispatch(%Event{request: request, opts: opts} = event) do
      send(self(), {:dispatched, opts[:action], request})

      response =
        case opts[:action] do
          :materialize_record ->
            {:ok, %Record{id: request.file_id, kind: :file, content: "bytes"}}

          :describe_records ->
            records =
              Enum.map(request.file_ids, &%Record{id: &1, kind: :file, name: "#{&1}.md"})

            {:ok, %RecordPage{resource_type: :file, records: records}}

          :persist_record ->
            {:ok, %Record{id: "new", kind: :file, name: Path.basename(request.path)}}

          :delete_record ->
            :ok
        end

      %{event | response: response}
    end
  end

  defmodule ErrorRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :forbidden}}
  end

  defmodule EmptyPageRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %RecordPage{resource_type: :file, records: []}}}
    end
  end

  @config %{provider: "disk", kind: "data_source"}

  describe "download_document/2" do
    test "dispatches materialize_record and wraps the record" do
      params = %{"file_id" => "42", "person_id" => nil, "node_router" => EchoRouter}

      assert {:ok, %{record: %Record{content: "bytes"}}} =
               DiskBridge.download_document(@config, params)

      assert_received {:dispatched, :materialize_record, %{file_id: "42", person_id: nil}}
    end

    test "carries person_id and team_ids through to ingestion" do
      params = %{
        "file_id" => "42",
        "person_id" => "p1",
        "team_ids" => ["t1"],
        "node_router" => EchoRouter
      }

      assert {:ok, _} = DiskBridge.download_document(@config, params)

      assert_received {:dispatched, :materialize_record, %{person_id: "p1", team_ids: ["t1"]}}
    end

    test "propagates an ingestion error" do
      params = %{"file_id" => "42", "node_router" => ErrorRouter}

      assert {:error, :forbidden} = DiskBridge.download_document(@config, params)
    end
  end

  describe "list_files/2" do
    test "dispatches describe_records and returns the page" do
      params = %{"file_ids" => ["1", "2"], "node_router" => EchoRouter}

      assert {:ok, %RecordPage{records: records}} = DiskBridge.list_files(@config, params)
      assert length(records) == 2
      assert_received {:dispatched, :describe_records, %{file_ids: ["1", "2"]}}
    end

    test "defaults to an empty id list" do
      assert {:ok, %RecordPage{}} =
               DiskBridge.list_files(@config, %{"node_router" => EchoRouter})

      assert_received {:dispatched, :describe_records, %{file_ids: []}}
    end
  end

  describe "get_file/2" do
    test "returns a single record" do
      params = %{"file_id" => "7", "node_router" => EchoRouter}

      assert {:ok, %{record: %Record{id: "7"}}} = DiskBridge.get_file(@config, params)
    end

    test "returns not_found when the page comes back empty" do
      params = %{"file_id" => "7", "node_router" => EmptyPageRouter}

      assert {:error, :not_found} = DiskBridge.get_file(@config, params)
    end

    test "propagates an error" do
      params = %{"file_id" => "7", "node_router" => ErrorRouter}

      assert {:error, :forbidden} = DiskBridge.get_file(@config, params)
    end
  end

  describe "create_file/2" do
    test "dispatches persist_record with tags" do
      params = %{
        "volume" => "vol",
        "path" => "refs/a.md",
        "content" => "x",
        "tags" => ["public"],
        "node_router" => EchoRouter
      }

      assert {:ok, %{record: %Record{name: "a.md"}}} = DiskBridge.create_file(@config, params)

      assert_received {:dispatched, :persist_record,
                       %{volume: "vol", path: "refs/a.md", tags: ["public"]}}
    end

    test "defaults to no tags" do
      params = %{
        "volume" => "vol",
        "path" => "a.md",
        "content" => "x",
        "node_router" => EchoRouter
      }

      assert {:ok, _} = DiskBridge.create_file(@config, params)
      assert_received {:dispatched, :persist_record, %{tags: []}}
    end

    test "propagates an error" do
      params = %{"volume" => "v", "path" => "a", "node_router" => ErrorRouter}

      assert {:error, :forbidden} = DiskBridge.create_file(@config, params)
    end
  end

  describe "delete_file/2" do
    test "dispatches delete_record" do
      params = %{"file_id" => "9", "node_router" => EchoRouter}

      assert :ok = DiskBridge.delete_file(@config, params)
      assert_received {:dispatched, :delete_record, %{file_id: "9"}}
    end
  end

  describe "params" do
    test "accepts atom keys as well as string keys" do
      params = %{file_id: "42", node_router: EchoRouter}

      assert {:ok, %{record: %Record{content: "bytes"}}} =
               DiskBridge.download_document(@config, params)
    end
  end

  describe "registration" do
    test "the disk provider resolves to this bridge" do
      assert {:ok, DiskBridge} = Bridge.resolve_bridge("disk")
    end

    test "disk declares a static config so no channel_configs row is needed" do
      assert %{provider: "disk", kind: "data_source"} = Bridge.static_channel_config("disk")
    end

    test "providers with real credentials declare no static config" do
      assert Bridge.static_channel_config("google_drive") == nil
    end
  end
end
