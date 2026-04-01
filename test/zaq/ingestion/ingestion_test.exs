defmodule Zaq.IngestionTest do
  use Zaq.DataCase, async: true

  import Mox

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
          chunk_index,
          role_id,
          shared_role_ids
        ) do
      Chunk.create(%{
        document_id: document_id,
        content: chunk.content,
        chunk_index: chunk_index,
        role_id: role_id,
        shared_role_ids: shared_role_ids
      })
    end
  end

  describe "ingest_file/2" do
    test "creates a job and enqueues worker in async mode" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path,
                                                                 _role_id,
                                                                 _shared_role_ids ->
        {:ok, %{id: nil, chunks_count: 2, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :async)
      assert job.status == "pending"
      assert job.mode == "async"
      assert job.file_path == "docs/file.md"
    end

    test "creates a job and processes inline" do
      Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path,
                                                                 _role_id,
                                                                 _shared_role_ids ->
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

      expect(Zaq.DocumentProcessorMock, :process_single_file, 2, fn _path,
                                                                    _role_id,
                                                                    _shared_role_ids ->
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

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path,
                                                                 _role_id,
                                                                 _shared_role_ids ->
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
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path,
                                                                 _role_id,
                                                                 _shared_role_ids ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline, "docs")
      assert job.volume_name == "docs"
    end

    test "nil volume_name when not provided (backward compat)" do
      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path,
                                                                 _role_id,
                                                                 _shared_role_ids ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, job} = Ingestion.ingest_file("docs/file.md", :inline)
      assert job.volume_name == nil
    end
  end

  describe "track_upload/3" do
    test "creates a document record with volume-prefixed source and uploader's role_id" do
      role = role_fixture()
      volume = "default"
      path = "file_#{System.unique_integer([:positive])}.md"

      assert {:ok, doc} = Ingestion.track_upload(volume, path, role.id)
      assert doc.source == Path.join([volume, path])
      assert doc.role_id == role.id
      assert doc.content == nil
    end

    test "upserts: does not duplicate when called again for the same source" do
      role1 = role_fixture()
      role2 = role_fixture()
      volume = "default"
      path = "file_#{System.unique_integer([:positive])}.md"

      assert {:ok, _} = Ingestion.track_upload(volume, path, role1.id)
      assert {:ok, doc} = Ingestion.track_upload(volume, path, role2.id)
      assert doc.role_id == role2.id
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

  describe "share_file/2" do
    test "updates shared_role_ids on an existing document" do
      role1 = role_fixture()
      role2 = role_fixture()
      source = "file_#{System.unique_integer([:positive])}.md"

      {:ok, _} = Document.upsert(%{source: source, role_id: role1.id})
      {:ok, _} = Document.upsert(%{source: source, role_id: role1.id})

      assert {:ok, _} = Ingestion.share_file(source, [role2.id])
      assert Document.get_by_source(source).shared_role_ids == [role2.id]
    end

    test "creates a minimal document when none exists yet" do
      role = role_fixture()
      source = "file_#{System.unique_integer([:positive])}.md"

      assert {:ok, _} = Ingestion.share_file(source, [role.id])

      doc = Document.get_by_source(source)
      assert doc.shared_role_ids == [role.id]
      assert doc.role_id == nil
    end

    test "does not overwrite ingested content" do
      role = role_fixture()
      source = "file_#{System.unique_integer([:positive])}.md"

      {:ok, _} = Document.upsert(%{source: source, content: "# Hello", role_id: role.id})
      {:ok, _} = Ingestion.share_file(source, [role.id])

      assert Document.get_by_source(source).content == "# Hello"
    end

    test "clears sharing when called with empty list" do
      role = role_fixture()
      source = "file_#{System.unique_integer([:positive])}.md"

      {:ok, _} = Document.upsert(%{source: source, role_id: role.id})
      {:ok, _} = Ingestion.share_file(source, [role.id])
      {:ok, _} = Ingestion.share_file(source, [])

      assert Document.get_by_source(source).shared_role_ids == []
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

      expect(Zaq.DocumentProcessorMock, :process_single_file, 1, fn _path,
                                                                    _role_id,
                                                                    _shared_role_ids ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, jobs} = Ingestion.ingest_folder(folder, :inline, "docs")
      assert Enum.all?(jobs, &(&1.volume_name == "docs"))
    end
  end
end
