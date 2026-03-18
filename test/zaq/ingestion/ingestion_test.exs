defmodule Zaq.IngestionTest do
  use Zaq.DataCase, async: true

  import Mox

  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, FileExplorer, IngestJob}
  alias Zaq.Repo

  setup do
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
    setup do
      prev = Application.get_env(:zaq, Zaq.Ingestion, [])

      Application.put_env(
        :zaq,
        Zaq.Ingestion,
        Keyword.merge(prev, volumes: %{"default" => "tmp/volumes/default"})
      )

      on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, prev) end)
      :ok
    end

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

  describe "share_file/2" do
    test "updates shared_role_ids on an existing document" do
      role1 = role_fixture()
      role2 = role_fixture()
      source = "file_#{System.unique_integer([:positive])}.md"

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
