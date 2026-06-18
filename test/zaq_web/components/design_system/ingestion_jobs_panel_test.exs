defmodule ZaqWeb.Components.DesignSystem.IngestionJobsPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Ingestion.IngestJob
  alias ZaqWeb.Components.DesignSystem.IngestionJobsPanel

  describe "jobs_panel/1 prep indicator" do
    test "renders started preparation text with default progress bounds" do
      job = processing_job("started.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{job.id => %{"status" => "started"}}
        )

      assert html =~ "Preparing"
      assert html =~ "analysing document"
      assert html =~ ~s(value="0")
      assert html =~ ~s(max="1")
    end

    test "renders labelled image progress" do
      job = processing_job("images.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{
            job.id => %{"label" => "page-1.png", "current" => 2, "total" => 5}
          }
        )

      assert html =~ "describing images 2/5"
      assert html =~ "page-1.png"
      assert html =~ ~s(value="2")
      assert html =~ ~s(max="5")
    end

    test "renders unlabelled image progress" do
      job = processing_job("unlabelled.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{job.id => %{"current" => 3, "total" => 4}}
        )

      assert html =~ "describing images 3/4"
      assert html =~ ~s(value="3")
      assert html =~ ~s(max="4")
    end

    test "renders fallback prep text and default progress values" do
      job = processing_job("fallback.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{job.id => %{"status" => "unknown"}}
        )

      assert html =~ "preparing"
      assert html =~ ~s(value="0")
      assert html =~ ~s(max="1")
    end

    test "clamps invalid progress values while retaining image progress text" do
      job = processing_job("invalid-progress.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{job.id => %{"current" => -1, "total" => 0}}
        )

      assert html =~ "describing images -1/0"
      assert html =~ ~s(value="0")
      assert html =~ ~s(max="1")
    end

    test "renders a starting placeholder when no progress has arrived yet" do
      job = processing_job("starting.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{}
        )

      assert html =~ "Preparing"
      assert html =~ "starting"
      # An indeterminate progress bar carries neither value nor max.
      refute html =~ ~s(value=)
    end

    test "clamps current to total so an overflowing bar never renders" do
      job = processing_job("overflow.pdf")

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{job.id => %{"current" => 5, "total" => 3}}
        )

      assert html =~ "describing images 5/3"
      assert html =~ ~s(value="3")
      assert html =~ ~s(max="3")
    end
  end

  describe "jobs_panel/1 job details" do
    test "renders chunk progress, failed chunks, embedding error link, and retry action" do
      job = %IngestJob{
        id: Ecto.UUID.generate(),
        file_path: "failed.pdf",
        status: "completed_with_errors",
        mode: "async",
        total_chunks: 5,
        ingested_chunks: 3,
        failed_chunks: 2,
        chunks_count: 0,
        error: "Embedding dimension mismatch: expected 1536, got 1024"
      }

      html =
        render_component(&IngestionJobsPanel.jobs_panel/1,
          jobs: [job],
          status_filter: "all",
          prep_progress: %{}
        )

      assert html =~ "Chunks: 3/5"
      assert html =~ ~s(value="3")
      assert html =~ ~s(max="5")
      assert html =~ "Failed chunks: 2"
      assert html =~ "Error details"
      assert html =~ "Embedding dimension mismatch"
      assert html =~ "/bo/system-config?tab=embedding"
      assert html =~ "Retry"
      assert html =~ ~s(phx-value-id="#{job.id}")
    end
  end

  defp processing_job(file_path) do
    %IngestJob{
      id: Ecto.UUID.generate(),
      file_path: file_path,
      status: "processing",
      mode: "async",
      total_chunks: 0,
      ingested_chunks: 0,
      failed_chunks: 0,
      chunks_count: 0
    }
  end
end
