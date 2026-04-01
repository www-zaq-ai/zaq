defmodule Zaq.Ingestion.IngestJobTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.IngestJob

  describe "changeset/2" do
    test "valid with required fields" do
      attrs = %{file_path: "docs/readme.md", status: "pending", mode: "async"}
      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      assert changeset.valid?
    end

    test "invalid without file_path" do
      attrs = %{status: "pending", mode: "async"}
      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).file_path
    end

    test "invalid with bad status" do
      attrs = %{file_path: "file.md", status: "unknown", mode: "async"}
      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "invalid with bad mode" do
      attrs = %{file_path: "file.md", status: "pending", mode: "batch"}
      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).mode
    end

    test "accepts all valid statuses" do
      for status <- IngestJob.statuses() do
        attrs = %{file_path: "file.md", status: status, mode: "inline"}
        assert IngestJob.changeset(%IngestJob{}, attrs).valid?
      end
    end

    test "accepts optional fields" do
      now = DateTime.utc_now()

      attrs = %{
        file_path: "file.md",
        status: "completed",
        mode: "async",
        error: nil,
        started_at: now,
        completed_at: now,
        chunks_count: 42,
        total_chunks: 50,
        ingested_chunks: 42,
        failed_chunks: 8,
        failed_chunk_indices: [4, 11],
        document_id: 1
      }

      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      assert changeset.valid?
    end

    test "accepts optional volume_name field" do
      attrs = %{
        file_path: "docs/readme.md",
        status: "pending",
        mode: "async",
        volume_name: "docs"
      }

      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :volume_name) == "docs"
    end

    test "valid without volume_name (backward compat)" do
      attrs = %{file_path: "docs/readme.md", status: "pending", mode: "async"}
      changeset = IngestJob.changeset(%IngestJob{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :volume_name) == nil
    end
  end
end
