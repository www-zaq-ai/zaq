defmodule Zaq.IngestionTest do
  use Zaq.DataCase, async: true

  import Mox

  alias Zaq.Accounts.People
  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Chunk, Document, DocumentChunker, FileExplorer, IngestChunkJob, IngestJob}
  alias Zaq.Repo
  alias Zaq.System.EmbeddingConfig

  setup do
    changeset =
      EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
        endpoint: "http://localhost:11434/v1",
        model: "test-model",
        dimension: "1536"
      })

    {:ok, _} = Zaq.System.save_embedding_config(changeset)
    Mox.set_mox_global()
    :ok
  end

  setup :verify_on_exit!

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp create_linked_documents(source_source, sidecar_source) do
    {:ok, _source_doc} =
      Document.create(%{
        source: source_source,
        content: "source content",
        metadata: %{"sidecar_source" => sidecar_source}
      })

    {:ok, _sidecar_doc} =
      Document.create(%{
        source: sidecar_source,
        content: "sidecar content",
        metadata: %{"source_document_source" => source_source}
      })

    :ok
  end

  defp create_document_with_chunks(source, chunk_count \\ 2, metadata \\ %{}) do
    {:ok, document} =
      Document.create(%{
        source: source,
        content: "content for #{source}",
        metadata: metadata
      })

    if chunk_count > 0 do
      Enum.each(1..chunk_count, fn chunk_index ->
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: document.id,
          content: "chunk #{chunk_index} for #{source}",
          chunk_index: chunk_index
        })
        |> Repo.insert!()
      end)
    end

    document
  end

  defmodule RetryChunkProcessor do
    alias Zaq.Ingestion.Chunk
    alias Zaq.Ingestion.DocumentChunker

    def store_chunk_with_metadata(
          %DocumentChunker.Chunk{} = chunk,
          document_id,
          chunk_index
        ) do
      Chunk.create(%{
        document_id: document_id,
        content: chunk.content,
        chunk_index: chunk_index
      })
    end
  end

  describe "ingest_file/2" do
    test "creates a job and enqueues worker in async mode" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil, chunks_count: 2, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :async)
      assert job.status == "pending"
      assert job.mode == "async"
      assert job.file_path == "docs/file.md"
    end

    test "creates a job and processes inline" do
      Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil, chunks_count: 3, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline)
      job_id = job.id
      assert job.status == "completed"
      assert job.mode == "inline"

      assert_receive {:job_updated, %{id: ^job_id, status: "processing"}}
      assert_receive {:job_updated, %{id: ^job_id, status: "completed"}}
    end
  end

  describe "ingest_folder/2" do
    test "creates one job per file and skips directories" do
      unique = System.unique_integer([:positive])
      folder = "ingestion_test_#{unique}"

      assert :ok = FileExplorer.create_directory(folder)
      assert :ok = FileExplorer.create_directory(Path.join(folder, "nested"))
      assert {:ok, _} = FileExplorer.upload(Path.join(folder, "one.md"), "# one")
      assert {:ok, _} = FileExplorer.upload(Path.join(folder, "two.md"), "# two")

      on_exit(fn ->
        _ = FileExplorer.delete_directory(folder)
      end)

      expect(Zaq.DocumentProcessorMock, :process_single_file, 2, fn _path ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, jobs} = Ingestion.ingest_folder(folder, :inline)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.status == "completed"))
    end

    test "returns error when folder cannot be listed" do
      assert {:error, :path_traversal} = Ingestion.ingest_folder("../..", :inline)
    end
  end

  describe "list_jobs/1" do
    test "returns all jobs ordered by inserted_at desc" do
      j1 = create_job(%{file_path: "a.md"})
      j2 = create_job(%{file_path: "b.md"})

      jobs = Ingestion.list_jobs()
      ids = Enum.map(jobs, & &1.id)

      assert j2.id in ids
      assert j1.id in ids
    end

    test "filters by status" do
      create_job(%{file_path: "a.md", status: "pending"})
      create_job(%{file_path: "b.md", status: "completed"})

      jobs = Ingestion.list_jobs(status: "pending")
      assert length(jobs) == 1
      assert hd(jobs).status == "pending"
    end

    test "paginates with page and per_page" do
      create_job(%{file_path: "one.md"})
      create_job(%{file_path: "two.md"})
      create_job(%{file_path: "three.md"})

      jobs = Ingestion.list_jobs(page: 2, per_page: 2)

      assert length(jobs) == 1
      assert hd(jobs).file_path == "one.md"
    end
  end

  describe "get_job/1" do
    test "returns job by id" do
      job = create_job()
      assert Ingestion.get_job(job.id).id == job.id
    end

    test "returns nil for unknown id" do
      assert Ingestion.get_job(Ecto.UUID.generate()) == nil
    end
  end

  describe "retry_job/1" do
    test "retries a failed job" do
      job = create_job(%{status: "failed", error: "something broke"})
      Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, retried} = Ingestion.retry_job(job.id)
      job_id = job.id
      assert retried.status == "pending"
      assert retried.error == nil
      assert_receive {:job_updated, %{id: ^job_id, status: "pending", error: nil}}
    end

    test "returns error if job is not failed" do
      job = create_job(%{status: "completed"})
      assert {:error, :not_failed} = Ingestion.retry_job(job.id)
    end

    test "retries a completed_with_errors job by enqueueing failed chunks only" do
      doc = create_document_with_chunks("retry-source.md", 0)

      job =
        create_job(%{
          status: "completed_with_errors",
          error: "2 chunks failed after retries",
          document_id: doc.id,
          failed_chunks: 2,
          failed_chunk_indices: [2, 5]
        })

      %IngestChunkJob{}
      |> IngestChunkJob.changeset(%{
        ingest_job_id: job.id,
        document_id: doc.id,
        chunk_index: 2,
        chunk_payload: %{"content" => "chunk two", "metadata" => %{}},
        status: "failed_final"
      })
      |> Repo.insert!()

      %IngestChunkJob{}
      |> IngestChunkJob.changeset(%{
        ingest_job_id: job.id,
        document_id: doc.id,
        chunk_index: 5,
        chunk_payload: %{"content" => "chunk five", "metadata" => %{}},
        status: "failed_final"
      })
      |> Repo.insert!()

      original_processor = Application.get_env(:zaq, :document_processor)

      on_exit(fn ->
        if is_nil(original_processor) do
          Application.delete_env(:zaq, :document_processor)
        else
          Application.put_env(:zaq, :document_processor, original_processor)
        end
      end)

      Application.put_env(:zaq, :document_processor, RetryChunkProcessor)

      assert {:ok, retried} = Ingestion.retry_job(job.id)
      assert retried.status == "pending"
      assert retried.error == nil

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status in ["processing", "completed"]
      assert updated.failed_chunk_indices == []
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.retry_job(Ecto.UUID.generate())
    end
  end

  describe "cancel_job/1" do
    test "cancels a pending job" do
      job = create_job(%{status: "pending"})
      Ingestion.subscribe()

      assert {:ok, cancelled} = Ingestion.cancel_job(job.id)
      job_id = job.id
      assert cancelled.status == "failed"
      assert cancelled.error == "cancelled"
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "cancelled"}}
    end

    test "returns error if job is not pending" do
      job = create_job(%{status: "processing"})
      assert {:error, :not_pending} = Ingestion.cancel_job(job.id)
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.cancel_job(Ecto.UUID.generate())
    end
  end

  describe "ingest_file/3 (volume-aware)" do
    test "stores volume_name on the created job" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline, "docs")
      assert job.volume_name == "docs"
    end

    test "nil volume_name when not provided (backward compat)" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline)
      assert job.volume_name == nil
    end
  end

  describe "track_upload/2" do
    test "creates a document record with volume-prefixed source" do
      volume = "default"
      path = "file_#{System.unique_integer([:positive])}.md"

      assert {:ok, doc} = Ingestion.track_upload(volume, path)
      assert doc.source == Path.join([volume, path])
      assert doc.content == nil
    end

    test "upserts: does not duplicate when called again for the same source" do
      volume = "default"
      path = "file_#{System.unique_integer([:positive])}.md"

      assert {:ok, _} = Ingestion.track_upload(volume, path)
      assert {:ok, _doc} = Ingestion.track_upload(volume, path)
      assert Repo.aggregate(Document, :count) >= 1
    end
  end

  describe "delete_path/4" do
    test "recursively deletes nested directories and cleans linked records" do
      unique = System.unique_integer([:positive])
      folder = "delete_recursive_#{unique}"
      nested = Path.join(folder, "nested")
      source_path = Path.join(nested, "report.pdf")
      sidecar_path = Path.join(nested, "report.md")
      source_source = Path.join("default", source_path)
      sidecar_source = Path.join("default", sidecar_path)

      assert :ok = FileExplorer.create_directory("default", nested)
      assert {:ok, _} = FileExplorer.upload("default", source_path, "%PDF")
      assert {:ok, _} = FileExplorer.upload("default", sidecar_path, "# sidecar")
      assert :ok = create_linked_documents(source_source, sidecar_source)

      source_doc = Document.get_by_source(source_source)
      sidecar_doc = Document.get_by_source(sidecar_source)

      assert {:ok, _} =
               Chunk.create(%{document_id: source_doc.id, content: "source", chunk_index: 0})

      assert {:ok, _} =
               Chunk.create(%{document_id: sidecar_doc.id, content: "sidecar", chunk_index: 0})

      assert :ok = Ingestion.delete_path("default", folder, "directory")

      root = FileExplorer.list_volumes()["default"]

      refute File.exists?(Path.join(root, folder))
      assert Document.get_by_source(source_source) == nil
      assert Document.get_by_source(sidecar_source) == nil
      assert Chunk.count_by_document(source_doc.id) == 0
      assert Chunk.count_by_document(sidecar_doc.id) == 0
    end

    test "normalizes already-missing sidecar files while deleting directories" do
      unique = System.unique_integer([:positive])
      folder = "delete_missing_sidecar_#{unique}"
      source_path = Path.join(folder, "report.pdf")
      sidecar_path = Path.join(folder, "report.md")
      source_source = Path.join("default", source_path)
      sidecar_source = Path.join("default", sidecar_path)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert {:ok, _} = FileExplorer.upload("default", source_path, "%PDF")

      {:ok, _} =
        Document.create(%{
          source: source_source,
          content: "source content",
          metadata: %{"sidecar_source" => sidecar_source}
        })

      assert :ok = Ingestion.delete_path("default", folder, "directory")
      assert Document.get_by_source(source_source) == nil
    end

    test "preserves missing single-file delete behavior" do
      unique = System.unique_integer([:positive])
      missing_file = "missing_file_#{unique}.txt"

      assert {:error, :enoent} = Ingestion.delete_path("default", missing_file, "file")
    end
  end

  describe "rename_entry/3 sidecar sync" do
    test "renaming source co-renames sidecar and updates metadata links" do
      unique = System.unique_integer([:positive])
      folder = "rename_sync_#{unique}"
      source_path = Path.join(folder, "report.pdf")
      sidecar_path = Path.join(folder, "report.md")
      renamed_source = Path.join(folder, "report-v2.pdf")
      renamed_sidecar = Path.join(folder, "report-v2.md")
      source_source = Path.join("default", source_path)
      sidecar_source = Path.join("default", sidecar_path)
      renamed_source_source = Path.join("default", renamed_source)
      renamed_sidecar_source = Path.join("default", renamed_sidecar)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert {:ok, _} = FileExplorer.upload("default", source_path, "%PDF")
      assert {:ok, _} = FileExplorer.upload("default", sidecar_path, "# sidecar")
      assert :ok = create_linked_documents(source_source, sidecar_source)

      on_exit(fn ->
        _ = FileExplorer.delete_directory("default", folder)
      end)

      assert :ok = Ingestion.rename_entry("default", source_path, renamed_source)

      root = FileExplorer.list_volumes()["default"]

      refute File.exists?(Path.join(root, source_path))
      refute File.exists?(Path.join(root, sidecar_path))
      assert File.exists?(Path.join(root, renamed_source))
      assert File.exists?(Path.join(root, renamed_sidecar))

      assert Document.get_by_source(source_source) == nil
      assert Document.get_by_source(sidecar_source) == nil

      assert %Document{} = source_doc = Document.get_by_source(renamed_source_source)
      assert source_doc.metadata["sidecar_source"] == renamed_sidecar_source

      assert %Document{} = sidecar_doc = Document.get_by_source(renamed_sidecar_source)
      assert sidecar_doc.metadata["source_document_source"] == renamed_source_source
    end

    test "moving source co-moves sidecar and updates metadata links" do
      unique = System.unique_integer([:positive])
      folder = "move_sync_#{unique}"
      source_path = Path.join(folder, "report.pdf")
      sidecar_path = Path.join(folder, "report.md")
      target_dir = Path.join(folder, "target")
      moved_source = Path.join(target_dir, "report.pdf")
      moved_sidecar = Path.join(target_dir, "report.md")
      source_source = Path.join("default", source_path)
      sidecar_source = Path.join("default", sidecar_path)
      moved_source_source = Path.join("default", moved_source)
      moved_sidecar_source = Path.join("default", moved_sidecar)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert :ok = FileExplorer.create_directory("default", target_dir)
      assert {:ok, _} = FileExplorer.upload("default", source_path, "%PDF")
      assert {:ok, _} = FileExplorer.upload("default", sidecar_path, "# sidecar")
      assert :ok = create_linked_documents(source_source, sidecar_source)

      on_exit(fn ->
        _ = FileExplorer.delete_directory("default", folder)
      end)

      assert :ok = Ingestion.rename_entry("default", source_path, moved_source)

      root = FileExplorer.list_volumes()["default"]

      refute File.exists?(Path.join(root, source_path))
      refute File.exists?(Path.join(root, sidecar_path))
      assert File.exists?(Path.join(root, moved_source))
      assert File.exists?(Path.join(root, moved_sidecar))

      assert Document.get_by_source(source_source) == nil
      assert Document.get_by_source(sidecar_source) == nil

      assert %Document{} = source_doc = Document.get_by_source(moved_source_source)
      assert source_doc.metadata["sidecar_source"] == moved_sidecar_source

      assert %Document{} = sidecar_doc = Document.get_by_source(moved_sidecar_source)
      assert sidecar_doc.metadata["source_document_source"] == moved_source_source
    end
  end

  describe "delete_path/4 and delete_paths/3 recursive cleanup" do
    test "deleting a directory removes nested documents and chunks" do
      unique = System.unique_integer([:positive])
      folder = "delete_recursive_#{unique}"
      nested_dir = Path.join(folder, "nested")
      root_file = Path.join(folder, "root.md")
      nested_file = Path.join(nested_dir, "deep.md")
      root_source = Path.join("default", root_file)
      nested_source = Path.join("default", nested_file)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert :ok = FileExplorer.create_directory("default", nested_dir)
      assert {:ok, _} = FileExplorer.upload("default", root_file, "# root")
      assert {:ok, _} = FileExplorer.upload("default", nested_file, "# deep")

      root_doc = create_document_with_chunks(root_source)
      nested_doc = create_document_with_chunks(nested_source)

      assert Chunk.count_by_document(root_doc.id) == 2
      assert Chunk.count_by_document(nested_doc.id) == 2

      on_exit(fn ->
        _ = FileExplorer.delete_directory("default", folder)
      end)

      assert :ok = Ingestion.delete_path("default", folder, "directory")

      assert Document.get(root_doc.id) == nil
      assert Document.get(nested_doc.id) == nil
      assert Chunk.count_by_document(root_doc.id) == 0
      assert Chunk.count_by_document(nested_doc.id) == 0
      assert Document.get_by_source(root_source) == nil
      assert Document.get_by_source(nested_source) == nil
    end

    test "bulk delete with a directory removes nested documents and chunks" do
      unique = System.unique_integer([:positive])
      folder = "bulk_delete_recursive_#{unique}"
      nested_dir = Path.join(folder, "nested")
      nested_file = Path.join(nested_dir, "deep.md")
      nested_source = Path.join("default", nested_file)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert :ok = FileExplorer.create_directory("default", nested_dir)
      assert {:ok, _} = FileExplorer.upload("default", nested_file, "# deep")

      nested_doc = create_document_with_chunks(nested_source)

      assert Chunk.count_by_document(nested_doc.id) == 2

      on_exit(fn ->
        _ = FileExplorer.delete_directory("default", folder)
      end)

      assert [{^folder, :ok}] = Ingestion.delete_paths("default", [folder])

      assert Document.get(nested_doc.id) == nil
      assert Chunk.count_by_document(nested_doc.id) == 0
      assert Document.get_by_source(nested_source) == nil
    end

    test "deleting a directory removes linked sidecar outside that directory" do
      unique = System.unique_integer([:positive])
      folder = "delete_sidecar_recursive_#{unique}"
      source_file = Path.join(folder, "diagram.png")
      outside_dir = "outside_sidecar_#{unique}"
      sidecar_file = Path.join(outside_dir, "diagram.md")
      source_source = Path.join("default", source_file)
      sidecar_source = Path.join("default", sidecar_file)

      assert :ok = FileExplorer.create_directory("default", folder)
      assert :ok = FileExplorer.create_directory("default", outside_dir)
      assert {:ok, _} = FileExplorer.upload("default", source_file, "binary")
      assert {:ok, _} = FileExplorer.upload("default", sidecar_file, "# sidecar")

      source_doc =
        create_document_with_chunks(source_source, 2, %{"sidecar_source" => sidecar_source})

      sidecar_doc =
        create_document_with_chunks(sidecar_source, 2, %{
          "source_document_source" => source_source
        })

      root = FileExplorer.list_volumes()["default"]
      assert File.exists?(Path.join(root, sidecar_file))

      on_exit(fn ->
        _ = FileExplorer.delete_directory("default", folder)
        _ = FileExplorer.delete_directory("default", outside_dir)
      end)

      assert :ok = Ingestion.delete_path("default", folder, "directory")

      assert Document.get(source_doc.id) == nil
      assert Document.get(sidecar_doc.id) == nil
      assert Chunk.count_by_document(source_doc.id) == 0
      assert Chunk.count_by_document(sidecar_doc.id) == 0
      assert Document.get_by_source(source_source) == nil
      assert Document.get_by_source(sidecar_source) == nil
      refute File.exists?(Path.join(root, sidecar_file))
    end
  end

  # ---------------------------------------------------------------------------
  # Permission helpers
  # ---------------------------------------------------------------------------

  defp create_person(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(
        Map.merge(
          %{"full_name" => "Test Person #{unique}", "email" => "person#{unique}@test.com"},
          attrs
        )
      )

    person
  end

  defp create_team(attrs \\ %{}) do
    {:ok, team} =
      People.create_team(Map.merge(%{name: "Team #{System.unique_integer([:positive])}"}, attrs))

    team
  end

  defp create_doc_with_source(source) do
    {:ok, doc} = Document.create(%{source: source, content: "content"})
    doc
  end

  # ---------------------------------------------------------------------------
  # Permission schema (changeset tests live in permission_test.exs, but we
  # test the public Ingestion context functions here)
  # ---------------------------------------------------------------------------

  describe "set_document_permission/4 and list_document_permissions/1" do
    test "creates a person permission" do
      doc = create_doc_with_source("perm-test-person.md")
      person = create_person()

      assert {:ok, perm} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])
      assert perm.person_id == person.id
      assert perm.access_rights == ["read"]

      perms = Ingestion.list_document_permissions(doc.id)
      assert length(perms) == 1
      assert hd(perms).person_id == person.id
    end

    test "creates a team permission" do
      doc = create_doc_with_source("perm-test-team.md")
      team = create_team()

      assert {:ok, perm} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])
      assert perm.team_id == team.id
    end

    test "upserts — updating existing permission changes access_rights" do
      doc = create_doc_with_source("perm-upsert.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      {:ok, updated} =
        Ingestion.set_document_permission(doc.id, :person, person.id, ["read", "write"])

      assert updated.access_rights == ["read", "write"]
      assert length(Ingestion.list_document_permissions(doc.id)) == 1
    end
  end

  describe "delete_document_permission/1" do
    test "deletes an existing permission" do
      doc = create_doc_with_source("del-perm.md")
      person = create_person()
      {:ok, perm} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert {:ok, _} = Ingestion.delete_document_permission(perm.id)
      assert Ingestion.list_document_permissions(doc.id) == []
    end

    test "returns error for missing permission" do
      assert {:error, :not_found} = Ingestion.delete_document_permission(-1)
    end
  end

  describe "list_person_permissions/1" do
    test "returns permissions for a given person across documents" do
      doc1 = create_doc_with_source("lpp-doc1.md")
      doc2 = create_doc_with_source("lpp-doc2.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      perms = Ingestion.list_person_permissions(person.id)
      assert length(perms) >= 2
      assert Enum.all?(perms, &(&1.person_id == person.id))
    end
  end

  describe "list_permitted_document_ids/3" do
    test "returns doc ids accessible by person" do
      doc = create_doc_with_source("permitted-person.md")
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      result = Ingestion.list_permitted_document_ids(person.id, [], [doc.id])
      assert doc.id in result
    end

    test "returns doc ids accessible by team" do
      doc = create_doc_with_source("permitted-team.md")
      team = create_team()
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      result = Ingestion.list_permitted_document_ids(person.id, [team.id], [doc.id])
      assert doc.id in result
    end

    test "excludes doc ids without any matching permission" do
      doc = create_doc_with_source("not-permitted.md")
      person = create_person()

      result = Ingestion.list_permitted_document_ids(person.id, [], [doc.id])
      refute doc.id in result
    end

    test "returns empty list when person_id does not exist" do
      doc = create_doc_with_source("nonexistent-person.md")
      non_existing_person_id = -1

      result = Ingestion.list_permitted_document_ids(non_existing_person_id, [], [doc.id])
      assert result == []
    end

    test "returns empty list when team_ids don't match any permissions" do
      doc = create_doc_with_source("nonexistent-team.md")
      person = create_person()

      result = Ingestion.list_permitted_document_ids(person.id, [-1, -2], [doc.id])
      assert result == []
    end

    test "handles duplicate doc_ids in input without duplicating results" do
      doc = create_doc_with_source("dup-doc-ids.md")
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      result = Ingestion.list_permitted_document_ids(person.id, [], [doc.id, doc.id, doc.id])
      assert Enum.count(result, &(&1 == doc.id)) == 1
    end

    test "returns mixed results for docs with and without permissions" do
      permitted_doc = create_doc_with_source("mixed-permitted.md")
      denied_doc = create_doc_with_source("mixed-denied.md")
      person = create_person()
      other_person = create_person()
      {:ok, _} = Ingestion.set_document_permission(permitted_doc.id, :person, person.id, ["read"])

      {:ok, _} =
        Ingestion.set_document_permission(denied_doc.id, :person, other_person.id, ["read"])

      result =
        Ingestion.list_permitted_document_ids(person.id, [], [permitted_doc.id, denied_doc.id])

      assert permitted_doc.id in result
      refute denied_doc.id in result
    end
  end

  describe "get_document_by_source!/1" do
    test "returns document when it exists" do
      doc = create_doc_with_source("get-doc-by-source.md")
      found = Ingestion.get_document_by_source!("get-doc-by-source.md")
      assert found.id == doc.id
    end

    test "raises when document not found" do
      assert_raise RuntimeError, fn ->
        Ingestion.get_document_by_source!("definitely-missing-#{System.unique_integer()}.md")
      end
    end
  end

  describe "list_documents_under_folder/2" do
    test "returns documents whose source starts with the given prefix" do
      folder = "vol/mydir"
      doc1 = create_doc_with_source("#{folder}/file1.md")
      doc2 = create_doc_with_source("#{folder}/nested/file2.md")
      _other = create_doc_with_source("other/file.md")

      results = Ingestion.list_documents_under_folder("vol", "mydir")
      ids = Enum.map(results, & &1.id)

      assert doc1.id in ids
      assert doc2.id in ids
    end
  end

  describe "list_folder_permissions/2" do
    test "returns unique permissions across all docs under a folder" do
      folder = "vol_fp/folder"
      doc1 = create_doc_with_source("#{folder}/a.md")
      doc2 = create_doc_with_source("#{folder}/b.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      perms = Ingestion.list_folder_permissions("vol_fp", "folder")
      person_perms = Enum.filter(perms, &(&1.person_id == person.id))
      assert length(person_perms) == 1
    end
  end

  describe "delete_folder_target_permission/3" do
    test "deletes all permissions for the same person across docs in folder" do
      folder = "vol_dfp/folder"
      doc1 = create_doc_with_source("#{folder}/a.md")
      doc2 = create_doc_with_source("#{folder}/b.md")
      person = create_person()

      {:ok, perm1} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _perm2} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      assert {:ok, 2} = Ingestion.delete_folder_target_permission("vol_dfp", "folder", perm1.id)
      assert Ingestion.list_document_permissions(doc1.id) == []
      assert Ingestion.list_document_permissions(doc2.id) == []
    end

    test "returns error when permission not found" do
      assert {:error, :not_found} =
               Ingestion.delete_folder_target_permission("vol", "folder", -1)
    end
  end

  describe "can_access_file?/2" do
    test "returns true when document has no permissions set (public by default)" do
      source = "public-doc-#{System.unique_integer()}.md"
      _doc = create_doc_with_source(source)
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "returns true when no document exists for the path" do
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      assert Ingestion.can_access_file?("no-such-file-#{System.unique_integer()}.md", user) ==
               true
    end

    test "super_admin bypasses all permission checks" do
      source = "restricted-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      other_person = create_person()
      role = %Zaq.Accounts.Role{name: "super_admin"}
      user = %{role: role, person_id: other_person.id, team_ids: []}

      # Set a permission for a different person — super_admin still gets in
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person with direct permission can access" do
      source = "restricted-person-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person with team permission can access" do
      source = "restricted-team-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      team = create_team()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: [team.id]}

      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person without any matching permission is denied" do
      source = "no-access-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      other_person = create_person()
      denied_person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: denied_person.id, team_ids: []}

      # Only other_person has permission
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, other_person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == false
    end
  end

  describe "source_for/2" do
    test "returns document source when document exists for the path" do
      source = "vol/file.md"
      _doc = create_doc_with_source(source)

      result = Ingestion.source_for("vol", "file.md")
      assert result == source
    end

    test "returns normalized relative path when no document exists" do
      result = Ingestion.source_for("vol", "missing-#{System.unique_integer()}.md")
      assert is_binary(result)
    end
  end

  describe "ingest_folder/3 (volume-aware)" do
    test "stores volume_name on all created jobs" do
      unique = System.unique_integer([:positive])
      folder = "ingestion_vol_test_#{unique}"

      # Configure a "docs" volume pointing at the same base path so files
      # created via FileExplorer.create_directory/upload are reachable.
      base_dir = FileExplorer.base_path() |> Path.expand()
      original = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(original || [], volumes: %{"docs" => base_dir})
      )

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:zaq, Zaq.Ingestion)
        else
          Application.put_env(:zaq, Zaq.Ingestion, original)
        end
      end)

      assert :ok = FileExplorer.create_directory(folder)
      assert {:ok, _} = FileExplorer.upload(Path.join(folder, "one.md"), "# one")

      on_exit(fn -> _ = FileExplorer.delete_directory(folder) end)

      expect(Zaq.DocumentProcessorMock, :process_single_file, 1, fn _path ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, jobs} = Ingestion.ingest_folder(folder, :inline, "docs")
      assert Enum.all?(jobs, &(&1.volume_name == "docs"))
    end
  end
end
