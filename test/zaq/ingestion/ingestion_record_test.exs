defmodule Zaq.Ingestion.RecordIngestionTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

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

  property "persisted materialization context contains only the supplied actor" do
    check all(
            actor_key <- member_of([:actor, "actor"]),
            actor <- member_of([nil, %{person_id: nil}, %{"person_id" => "person-1"}]),
            router_key <- member_of([:node_router, "node_router"]),
            router <- member_of([nil, Zaq.NodeRouterMock]),
            irrelevant <- map_of(string(:alphanumeric, min_length: 1), integer(), max_length: 5),
            max_runs: 30
          ) do
      record = %Record{
        id: Ecto.UUID.generate(),
        kind: :file,
        name: "Readme.md",
        attributes: %{"provider" => "google_drive", "config_id" => "cfg-1"}
      }

      params =
        irrelevant
        |> Map.new(fn {key, value} -> {"runtime_" <> key, value} end)
        |> Map.put(actor_key, actor)
        |> Map.put(router_key, router)
        |> Map.put(:skip_permissions, true)
        |> Map.put(:runtime_pid, self())

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, [job]} = Ingestion.ingest_records([record], params)
        reloaded = Repo.get!(IngestJob, job.id)

        if is_nil(actor) do
          refute Map.has_key?(reloaded.source_record, "materialization_context")
        else
          assert reloaded.source_record["materialization_context"] == %{
                   "actor" => Jason.decode!(Jason.encode!(actor))
                 }
        end
      end)
    end
  end
end
