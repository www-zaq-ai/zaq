defmodule Storybook.Components.DesignSystem.Dropzone do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Dropzone

  def description, do: "BO ingestion upload drop zone, queue, and skipped-folder list."

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
    <div style="padding: var(--zaq-scale-32); display: flex; flex-direction: column; gap: var(--zaq-scale-40);">
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          Empty queue, embedding ready
        </p>
        <.upload_section uploads={empty_uploads()} embedding_ready={true} folder_drop_skipped={[]} />
      </section>
      <section>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-12);"
        >
          With entry + skipped files
        </p>
        <.upload_section
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
        <.upload_section
          uploads={uploads_with_entry()}
          embedding_ready={false}
          folder_drop_skipped={[]}
        />
      </section>
    </div>
    """
  end
end
