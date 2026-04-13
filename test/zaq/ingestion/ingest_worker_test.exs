defmodule Zaq.Ingestion.IngestWorkerTest do
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Mox

  alias Zaq.Ingestion.{Document, IngestJob, IngestWorker}
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
    stub(Zaq.DocumentProcessorMock, :read_as_markdown, fn path -> File.read(path) end)
    :ok
  end

  setup :verify_on_exit!

  defp create_job(attrs \\ %{}) do
    path = Path.join(System.tmp_dir!(), "worker_test_#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Test")
    on_exit(fn -> File.rm(path) end)

    %IngestJob{}
    |> IngestJob.changeset(Map.merge(%{file_path: path, status: "pending", mode: "async"}, attrs))
    |> Repo.insert!()
  end

  defp create_document do
    %Document{}
    |> Document.changeset(%{
      source: "worker-test-#{System.unique_integer([:positive])}.md",
      content: "# Test"
    })
    |> Repo.insert!()
  end

  describe "perform/1" do
    test "returns :ok when Agent.run succeeds" do
      job = create_job()
      doc = create_document()

      expect(Zaq.DocumentProcessorMock, :prepare_file_chunks, fn _path ->
        {:ok, doc, []}
      end)

      Application.put_env(:zaq, :document_processor, Zaq.DocumentProcessorMock)

      on_exit(fn -> Application.delete_env(:zaq, :document_processor) end)

      result =
        IngestWorker.perform(%Oban.Job{
          args: %{"job_id" => job.id}
        })

      assert result == :ok
      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "completed"
    end

    test "returns {:cancel, :failed} when Agent.run fails (non-retryable)" do
      # Relative path that doesn't exist → UploadFile fails → Agent returns {:error, job}
      job =
        %IngestJob{}
        |> IngestJob.changeset(%{
          file_path: "nonexistent/file.md",
          status: "pending",
          mode: "async"
        })
        |> Repo.insert!()

      result =
        IngestWorker.perform(%Oban.Job{
          args: %{"job_id" => job.id}
        })

      assert result == {:cancel, :failed}
      updated = Repo.get!(IngestJob, job.id)
      assert updated.status == "failed"
    end

    test "backoff scales linearly by attempt" do
      assert IngestWorker.backoff(%Oban.Job{attempt: 1}) == 5
      assert IngestWorker.backoff(%Oban.Job{attempt: 3}) == 15
    end
  end
end
