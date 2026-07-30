defmodule Storybook.Components.DesignSystem.ModalSkillResources do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ModalSkillResources

  def description,
    do: "Skill reference upload modal, and the no-volume dead end that gates it."

  defp uploads(entries \\ []) do
    %{
      skill_resources: %Phoenix.LiveView.UploadConfig{
        ref: "phx-skill-upload-ref",
        entries: entries,
        errors: [],
        name: :skill_resources,
        accept: :any,
        max_entries: 10,
        max_file_size: 20_000_000,
        chunk_size: 64_000,
        chunk_timeout: 10_000,
        external: false,
        auto_upload?: false,
        progress_event: nil
      }
    }
  end

  defp queued_entry do
    [
      %Phoenix.LiveView.UploadEntry{
        ref: "phx-ref-1",
        uuid: "uuid-1",
        upload_ref: "phx-skill-upload-ref",
        upload_config: :skill_resources,
        client_name: "pricing-table.pdf",
        client_size: 24_000,
        client_type: "application/pdf",
        client_relative_path: nil,
        done?: false,
        cancelled?: false,
        preflighted?: false,
        progress: 68,
        valid?: true
      }
    ]
  end

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-48);">
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Single volume — no picker
        </p>
        <.modal_skill_resources
          uploads={uploads()}
          volumes={%{"documents" => "/vol/documents"}}
          current_volume="documents"
          destination=".agents/skills/pricing-faq/references"
          hint=".json .md .pdf .png — max 5.0 MB"
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Several volumes — operator picks the destination volume
        </p>
        <.modal_skill_resources
          uploads={uploads()}
          volumes={%{"documents" => "/vol/documents", "archives" => "/vol/archives"}}
          current_volume="archives"
          destination=".agents/skills/pricing-faq/references"
          hint=".json .md .pdf .png — max 5.0 MB"
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          File queued
        </p>
        <.modal_skill_resources
          uploads={uploads(queued_entry())}
          volumes={%{"documents" => "/vol/documents"}}
          current_volume="documents"
          destination=".agents/skills/pricing-faq/references"
          hint=".json .md .pdf .png — max 5.0 MB"
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          No volume connected — the gate shown instead of the upload modal
        </p>
        <.modal_no_volume />
      </section>
    </div>
    """
  end
end
