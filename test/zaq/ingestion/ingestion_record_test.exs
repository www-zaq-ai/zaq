defmodule Zaq.Ingestion.RecordIngestionTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Mox
  import ExUnit.CaptureLog

  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.Ingestion.IngestJob
  alias Zaq.Ingestion.RecordSource
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

  property "watch ingestion preserves signed canonical projections across persistence" do
    check all(
            id <- string(:alphanumeric, min_length: 1, max_length: 30),
            projection <- member_of([:json, :atom]),
            permission_state <- member_of([:not_loaded, :empty, :loaded]),
            max_runs: 20
          ) do
      {:ok, permission} =
        Provenance.seal(%Record{
          id: "reader",
          kind: :permission,
          attributes: %{
            "principal" => %{"channel" => "email", "identifier" => "reader@example.test"},
            "access_rights" => ["read"]
          }
        })

      permissions =
        case permission_state do
          :not_loaded -> nil
          :empty -> []
          :loaded -> [permission]
        end

      {:ok, record} =
        Provenance.seal(%Record{
          id: id,
          kind: :file,
          name: "Changed.md",
          parent_id: "watched-folder",
          parent_ids: ["watched-folder"],
          permissions: permissions,
          materialization_handle: "preserve-opaque-handle",
          attributes: %{"provider" => "google_drive", "config_id" => "watch-config"}
        })

      {:ok, _} =
        Document.upsert(%{
          source: "data_source/google_drive/watch-config/#{id}",
          watch_status: "watched"
        })

      map =
        if projection == :json,
          do: Jason.decode!(Jason.encode!(record)),
          else: Map.from_struct(record)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [job], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: "watch-config",
                   signals: [%{record: map, change_type: :updated}]
                 })

        stored = Repo.get!(IngestJob, job.id).source_record
        assert {:ok, restored} = RecordSource.from_storage_map(stored)
        assert restored.provenance_ref == record.provenance_ref
        assert restored.materialization_handle == record.materialization_handle
        assert restored.permissions == permissions
        assert restored.parent_id == record.parent_id
        assert restored.parent_ids == record.parent_ids
      end)
    end
  end

  property "watch maps with invalid provenance never become ingestion jobs" do
    check all(
            id <- string(:alphanumeric, min_length: 1, max_length: 20),
            mutation <- member_of([:identity, :permissions, :signature, :missing]),
            max_runs: 20
          ) do
      {:ok, record} =
        Provenance.seal(%Record{id: id, kind: :file, permissions: nil})

      map = Jason.decode!(Jason.encode!(record))

      map =
        case mutation do
          :identity -> Map.put(map, "id", id <> "-tampered")
          :permissions -> Map.put(map, "permissions", [])
          :signature -> Map.put(map, "provenance_ref", "invalid")
          :missing -> Map.put(map, "provenance_ref", nil)
        end

      {:ok, _} =
        Document.upsert(%{
          source: "data_source/google_drive/watch-config/#{map["id"]}",
          watch_status: "watched"
        })

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: "watch-config",
                   records: [map]
                 })

        assert Repo.aggregate(IngestJob, :count) == 0
      end)
    end
  end

  test "rejected canonical maps log identity and reason without sensitive projections" do
    for map <- [
          %{id: "rejected-watch", kind: :file, provenance_ref: "private-token"},
          %{"id" => "rejected-watch", "kind" => "file", "provenance_ref" => "private-token"}
        ] do
      log =
        capture_log(fn ->
          assert {:ok, %{jobs: [], removed: 0}} =
                   Ingestion.process_data_source_changes(%{
                     records: [Map.put(map, "raw", %{"secret" => "private-payload"})]
                   })
        end)

      assert log =~ "[warning]"
      assert log =~ "Rejected data-source record id=\"rejected-watch\""
      assert log =~ "reason=:invalid_record_provenance"
      refute log =~ "private-token"
      refute log =~ "private-payload"
      assert Repo.aggregate(IngestJob, :count) == 0
    end
  end

  property "rejection diagnostics bound and escape untrusted identifiers" do
    check all(id <- binary(min_length: 129, max_length: 512), max_runs: 20) do
      log =
        capture_log(fn ->
          assert {:ok, %{jobs: [], removed: 0}} =
                   Ingestion.process_data_source_changes(%{
                     records: [%{id: id, kind: :file, provenance_ref: nil}]
                   })
        end)

      assert log =~ "Rejected data-source record"
      assert log =~ "reason=:missing_record_provenance"
      assert byte_size(log) < 2_000
      assert length(String.split(String.trim(log), "\n")) == 1
    end
  end

  test "unsigned JSON tombstones still delete only watched documents" do
    for status <- ["watched", "unwatched"] do
      id = "removed-#{status}"

      {:ok, document} =
        Document.insert_new(%{
          source: "data_source/google_drive/watch-config/#{id}",
          watch_status: status
        })

      tombstone = %Record{id: id, kind: :file, change_type: :deleted, lifecycle_state: :deleted}
      removed = if status == "watched", do: 1, else: 0

      assert {:ok, %{jobs: [], removed: ^removed}} =
               Ingestion.process_data_source_changes(%{
                 provider: "google_drive",
                 config_id: "watch-config",
                 signals: [%{removed?: true, record: Jason.decode!(Jason.encode!(tombstone))}]
               })

      assert is_nil(Repo.get(Document, document.id)) == (status == "watched")
    end
  end
end
