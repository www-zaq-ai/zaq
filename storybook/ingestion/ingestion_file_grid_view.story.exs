defmodule Storybook.Ingestion.IngestionFileGridView do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionFileGridView

  @dt ~U[2025-01-10 08:00:00Z]
  @dt_older ~U[2024-06-01 10:00:00Z]
  @dt_newer ~U[2025-06-15 16:30:00Z]

  def description,
    do: "Ingestion file browser — card grid: empty directory and representative cards."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:empty, MapSet.new())
      |> assign(:selected_one, MapSet.new([Path.join(".", "final.pdf")]))

    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-8"
      style="padding: var(--zaq-scale-32); max-width: 100%;"
    >
      <.story_block title="Empty directory" description="No files — empty message only.">
        <.file_grid_view
          entries={[]}
          selected={@empty}
          current_dir="."
          current_volume="default"
          ingestion_map={%{}}
        />
      </.story_block>

      <.story_block
        title="Converted markdown sidecar (PDF)"
        description={
          "Same sidecar data as list view: related .md preview on the card. " <>
            "Grid: button.zaq-table-sidecar-preview.zaq-table-sidecar-preview--ingestion-grid " <>
            "(filename in .zaq-table-sidecar-preview-name)."
        }
      >
        <.file_grid_view
          entries={sidecar_only_entries()}
          selected={@empty}
          current_dir="."
          current_volume="default"
          ingestion_map={sidecar_only_ingestion_map()}
        />
      </.story_block>

      <.story_block
        title="Populated directory"
        description="Folders, file statuses, shared/public badges, sidecar preview link, and one selected card."
      >
        <.file_grid_view
          entries={fixture_entries()}
          selected={@selected_one}
          current_dir="."
          current_volume="default"
          ingestion_map={fixture_ingestion_map()}
        />
      </.story_block>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :inner_block, required: true

  defp story_block(assigns) do
    ~H"""
    <section class="flex flex-col gap-3 min-w-0">
      <header>
        <h2 class="zaq-text-body font-semibold" style="color: var(--zaq-text-color-body-primary);">
          {@title}
        </h2>
        <p
          :if={@description}
          class="zaq-text-body-sm mt-1"
          style="color: var(--zaq-text-color-body-tertiary);"
        >
          {@description}
        </p>
      </header>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp fixture_entries do
    [
      %{name: "Projects", type: :directory, size: 0, modified_at: @dt},
      %{name: "Archive", type: :directory, size: 0, modified_at: @dt_older},
      %{name: "notes.md", type: :file, size: 1200, modified_at: @dt},
      %{name: "report.pdf", type: :file, size: 890_000, modified_at: @dt},
      %{name: "queue.docx", type: :file, size: 44_000, modified_at: @dt},
      %{name: "bad.csv", type: :file, size: 200, modified_at: @dt},
      %{name: "legacy.pdf", type: :file, size: 50_000, modified_at: @dt_newer},
      %{name: "final.pdf", type: :file, size: 30_000, modified_at: @dt_older},
      %{name: "team-notes.txt", type: :file, size: 400, modified_at: @dt},
      %{name: "readme.md", type: :file, size: 800, modified_at: @dt},
      %{name: "both-access.docx", type: :file, size: 12_000, modified_at: @dt},
      %{name: "locked.bin", type: :file, size: 99, modified_at: @dt},
      %{
        name: "slide.pdf",
        type: :file,
        size: 2_000_000,
        modified_at: @dt,
        attributes: %{
          "related_record" => %{"name" => "slide.md", "path" => "slide.md", "size" => 18_000}
        }
      }
    ]
  end

  defp fixture_ingestion_map do
    %{
      "Projects" => %{
        type: :directory,
        total_size: 500_000,
        file_count: 5,
        ingested_count: 3,
        is_public: false
      },
      "Archive" => %{
        type: :directory,
        total_size: 1_024,
        file_count: 4,
        ingested_count: 4,
        is_public: true
      },
      "notes.md" => %{
        ingested_at: nil,
        stale?: false,
        job_status: nil,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "report.pdf" => %{
        job_status: "processing",
        ingested_at: nil,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "queue.docx" => %{
        job_status: "pending",
        ingested_at: nil,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "bad.csv" => %{
        job_status: "failed",
        ingested_at: nil,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "legacy.pdf" => %{
        ingested_at: @dt_older,
        stale?: true,
        job_status: nil,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "final.pdf" => %{
        ingested_at: @dt,
        stale?: false,
        job_status: nil,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      },
      "team-notes.txt" => %{
        ingested_at: @dt,
        stale?: false,
        permissions_count: 2,
        is_public: false,
        can_share?: true
      },
      "readme.md" => %{
        ingested_at: @dt,
        stale?: false,
        permissions_count: 0,
        is_public: true,
        can_share?: true
      },
      "both-access.docx" => %{
        ingested_at: @dt,
        stale?: false,
        permissions_count: 1,
        is_public: true,
        can_share?: true
      },
      "locked.bin" => %{
        ingested_at: nil,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: false
      },
      "slide.pdf" => %{
        ingested_at: @dt,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      }
    }
  end

  defp sidecar_only_entries do
    [
      %{
        name: "demo.pdf",
        type: :file,
        size: 42_000,
        modified_at: @dt,
        attributes: %{
          "related_record" => %{"name" => "demo.md", "path" => "demo.md", "size" => 9_800}
        }
      }
    ]
  end

  defp sidecar_only_ingestion_map do
    %{
      "demo.pdf" => %{
        ingested_at: @dt,
        stale?: false,
        permissions_count: 0,
        is_public: false,
        can_share?: true
      }
    }
  end
end
