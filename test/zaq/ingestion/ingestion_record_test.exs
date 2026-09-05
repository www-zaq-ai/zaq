defmodule Zaq.Ingestion.RecordIngestionTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Ingestion
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Repo

  setup do
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
               Ingestion.ingest_records([folder], %{
                 mode: "async",
                 node_router: Zaq.NodeRouterMock
               })

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
