defmodule Zaq.Ingestion.RecordIngestionTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Ingestion
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  setup do
    {Zaq.NodeRouter, node_router_binary, node_router_path} =
      :code.get_object_code(Zaq.NodeRouter)

    node_router_stub = """
    defmodule Zaq.NodeRouter do
      alias Zaq.Event

      def dispatch(%Event{} = event), do: dispatch(event, %{})
      def dispatch(%Event{} = event, _runtime), do: Zaq.NodeRouterMock.dispatch(event)
      def find_node(supervisor), do: Zaq.NodeRouterMock.find_node(supervisor)
      def invoke(role, mod, fun, args), do: Zaq.NodeRouterMock.invoke(role, mod, fun, args)
      def invoke(role, mod, fun, args, runtime), do: Zaq.NodeRouterMock.invoke(role, mod, fun, args, runtime)
      def call(role, mod, fun, args), do: Zaq.NodeRouterMock.call(role, mod, fun, args)
      def fire(%Event{} = event), do: event
    end
    """

    :code.purge(Zaq.NodeRouter)
    :code.delete(Zaq.NodeRouter)
    Code.compile_string(node_router_stub)

    tmp_dir =
      Path.join(System.tmp_dir!(), "ingestion_record_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.write!(Path.join(tmp_dir, "docs/readme.md"), "# Readme")

    previous = Application.get_env(:zaq, Zaq.Ingestion)

    Application.put_env(:zaq, Zaq.Ingestion,
      base_path: tmp_dir,
      volumes: %{"docs" => Path.join(tmp_dir, "docs")}
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.Ingestion, previous || [])
      File.rm_rf!(tmp_dir)

      :code.purge(Zaq.NodeRouter)
      :code.delete(Zaq.NodeRouter)
      :code.load_binary(Zaq.NodeRouter, node_router_path, node_router_binary)
    end)

    %{tmp_dir: tmp_dir}
  end

  setup :verify_on_exit!

  test "ingest_record/2 rejects unsupported record kinds without creating a job" do
    before = Repo.aggregate(IngestJob, :count)

    assert {:error, :unsupported_record_kind} =
             Ingestion.ingest_record(%Record{id: "permission-1", kind: :permission})

    assert Repo.aggregate(IngestJob, :count) == before
  end

  test "ingest_records/2 lists an external folder and reports unsupported children" do
    folder = %Record{
      id: "folder-1",
      kind: :folder,
      name: "Folder",
      attributes: %{
        "provider" => "google_drive",
        "config_id" => "cfg-1",
        "provider_record_id" => "folder-1"
      }
    }

    valid = %Record{id: "file-1", kind: :file, name: "File.md"}
    unsupported = %Record{id: "permission-1", kind: :permission, name: "Permission"}

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      assert event.next_hop.destination == :channels
      assert event.request.provider == "google_drive"

      assert event.request.params == %{
               "config_id" => "cfg-1",
               "filters" => %{"parent" => "folder-1", "include_shared" => false},
               "include_permissions" => true
             }

      assert event.opts[:action] == :data_source_list_files

      %{
        event
        | response: {:ok, %RecordPage{resource_type: :folder, records: [valid, unsupported]}}
      }
    end)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:error, {:partial_failure, [job], [error]}} =
               Ingestion.ingest_records([folder], %{mode: "async"})

      assert job.mode == "async"

      assert error == %{
               record: %{id: "permission-1", name: "Permission"},
               reason: :unsupported_record_kind
             }
    end)
  end

  test "ingest_records/2 accepts an empty inline batch without creating jobs" do
    assert {:ok, []} = Ingestion.ingest_records([], %{mode: :inline})
    assert Repo.aggregate(IngestJob, :count) == 0
  end
end
