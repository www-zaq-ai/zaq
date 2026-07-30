defmodule Storybook.Ingestion.ModalUpload do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ModalUpload

  def description,
    do: "Upload data modal (`BOModal.form_dialog` + `Dropzone.upload_section`)."

  defp empty_uploads do
    %{
      files: %Phoenix.LiveView.UploadConfig{
        ref: "phx-upload-ref",
        entries: [],
        errors: [],
        name: :files,
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

  defp uploads_with_entry do
    entry = %Phoenix.LiveView.UploadEntry{
      ref: "phx-ref-1",
      uuid: "uuid-1",
      upload_ref: "phx-upload-ref",
      upload_config: :files,
      client_name: "notes.md",
      client_size: 1200,
      client_type: "text/markdown",
      client_relative_path: nil,
      done?: false,
      cancelled?: false,
      preflighted?: false,
      progress: 42,
      valid?: true
    }

    %{
      files: %Phoenix.LiveView.UploadConfig{
        ref: "phx-upload-ref",
        entries: [entry],
        errors: [],
        name: :files,
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

  def render(assigns) do
    ~H"""
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-48);">
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Empty queue, embedding ready
        </p>
        <.modal_upload uploads={empty_uploads()} embedding_ready={true} folder_drop_skipped={[]} />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          With entry + skipped files
        </p>
        <.modal_upload
          uploads={uploads_with_entry()}
          embedding_ready={true}
          folder_drop_skipped={[
            %{"name" => "bad.bin", "path" => "bad.bin", "reason" => "unsupported_format"}
          ]}
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Upload disabled (embedding not ready)
        </p>
        <.modal_upload
          uploads={uploads_with_entry()}
          embedding_ready={false}
          folder_drop_skipped={[]}
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Configured for skill resources — volume picker + destination, no folder drop
        </p>
        <.modal_upload
          id="skill-resource-modal"
          title="Add resource"
          uploads={skill_uploads()}
          volumes={%{"documents" => "/vol/documents", "archives" => "/vol/archives"}}
          current_volume="documents"
          volume_event="select_resource_volume"
          destination=".agents/skills/pricing-faq/references"
          upload_name={:skill_resources}
          id_prefix="skill-resource"
          submit_event="upload_skill_resource"
          change_event="validate_skill_resource"
          file_cancel_event="cancel_skill_resource"
          label="Reference file"
          submit_label="Add"
          hint=".json .md .pdf .png — max 5.0 MB"
          folder_drop?={false}
        />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Blocked — no volume connected
        </p>
        <.modal_no_volume />
      </section>
    </div>
    """
  end

  defp skill_uploads do
    %{
      skill_resources: %Phoenix.LiveView.UploadConfig{
        ref: "phx-upload-ref",
        entries: [],
        errors: [],
        name: :skill_resources,
        accept: :any,
        max_entries: 10,
        max_file_size: 5_242_880,
        chunk_size: 64_000,
        chunk_timeout: 10_000,
        external: false,
        auto_upload?: false,
        progress_event: nil
      }
    }
  end
end
