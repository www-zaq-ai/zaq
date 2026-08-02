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

  # Raises if dispatched — a request rejected on shape must never reach ingestion.
  defmodule ForbiddenRouter do
    def dispatch(%Event{}), do: raise("dispatch must not be called")
  end

  defmodule EmptyPageRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %RecordPage{resource_type: :file, records: []}}}
    end
  end

  @config %{provider: "disk", kind: "data_source"}

  # Unlike every other callback here, this one dispatches nothing: the bytes live on an
  # ingestion volume, so reading them here would route the payload ingestion → channels →
  # caller. It answers with the address and the event that fetches it, and the caller's
  # `Materializer` takes the second hop straight to ingestion.
  describe "download_document/2" do
    test "answers with an unmaterialized record and dispatches nothing" do
      params = %{"file_id" => "42", "person_id" => nil, "node_router" => ForbiddenRouter}

      assert {:ok, %{record: %Record{id: "42", kind: :file, content: nil} = record}} =
               DiskBridge.download_document(@config, params)

      assert %Event{} = record.materializing_event
    end

    test "aims the carried event at ingestion's materialize_record" do
      params = %{"file_id" => "42", "node_router" => ForbiddenRouter}

      assert {:ok, %{record: %Record{materializing_event: event}}} =
               DiskBridge.download_document(@config, params)

      assert event.next_hop.destination == :ingestion
      assert event.opts[:action] == :materialize_record
    end

    # The permission context has to survive onto the deferred event, or the second hop
    # arrives at `DocumentAccess` as an anonymous read and the file is refused.
    test "carries file_id, person_id and team_ids onto the deferred event" do
      params = %{
        "file_id" => "42",
        "person_id" => "p1",
        "team_ids" => ["t1"],
        "node_router" => ForbiddenRouter
      }

      assert {:ok, %{record: %Record{materializing_event: event}}} =
               DiskBridge.download_document(@config, params)

      assert event.request == %{file_id: "42", person_id: "p1", team_ids: ["t1"]}
    end

    # Errors now surface on the hop that reads the file, not on this call — the bridge no
    # longer touches ingestion, so there is nothing here that can fail.
    test "does not reach ingestion, so an ingestion error cannot surface here" do
      params = %{"file_id" => "42", "node_router" => ErrorRouter}

      assert {:ok, %{record: %Record{}}} = DiskBridge.download_document(@config, params)
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

    # `create_document` is a generic datasource tool: it sends a provider path and no volume
    # at all. Reaching this bridge with those params used to raise a `FunctionClauseError`
    # from `FileExplorer.upload_unique/3` rather than returning something reportable.
    test "refuses a call with no volume instead of crashing" do
      params = %{"path" => "notes/a.md", "content" => "x", "node_router" => ForbiddenRouter}

      assert {:error, :volume_required} = DiskBridge.create_file(@config, params)
    end

    test "refuses a call with no path" do
      params = %{"volume" => "vol", "content" => "x", "node_router" => ForbiddenRouter}

      assert {:error, :path_required} = DiskBridge.create_file(@config, params)
    end

    test "refuses an empty volume" do
      params = %{"volume" => "", "path" => "a.md", "node_router" => ForbiddenRouter}

      assert {:error, :volume_required} = DiskBridge.create_file(@config, params)
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
      params = %{file_id: "42", node_router: ForbiddenRouter}

      assert {:ok, %{record: %Record{id: "42", materializing_event: event}}} =
               DiskBridge.download_document(@config, params)

      assert event.request.file_id == "42"
    end
  end

  describe "registration" do
    test "the disk provider resolves to this bridge" do
      assert {:ok, DiskBridge} = Bridge.resolve_bridge("disk")
    end

    # Nothing about the config is written out anywhere: `config.exs` names only the bridge.
    # A config with no row behind it — no `:id`, no settings — is all this bridge ever gets,
    # and it works, because it never reads the config at all.
    test "works with the bare config a provider with no row is handed" do
      params = %{"file_id" => "42", "node_router" => EchoRouter}

      assert {:ok, %{record: %Record{id: "42"}}} =
               DiskBridge.download_document(%{provider: "disk"}, params)

      assert {:ok, %RecordPage{}} = DiskBridge.list_files(%{provider: "disk"}, params)
    end
  end
end
