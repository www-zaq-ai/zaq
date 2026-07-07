defmodule ZaqWeb.Components.DesignSystem.IngestionFileGridView do
  @moduledoc """
  BO ingestion file browser — card grid view.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.IngestionFileIcon, as: IngFileIcon
  import IngFileIcon, only: [file_icon_color: 1]

  import ZaqWeb.Components.DesignSystem.IngestionFileStatus

  alias ZaqWeb.Components.DesignSystem.StatusPill
  alias ZaqWeb.Helpers.SizeFormat

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :provider_mode, :boolean, default: false

  def file_grid_view(assigns) do
    ~H"""
    <div class="zaq-file-preview-shell max-h-[45vh] overflow-y-scroll flex flex-col min-h-0">
      <table class="zaq-table zaq-table--ingestion-grid-header w-full shrink-0">
        <thead>
          <tr class="sticky top-0 z-10">
            <th class="w-6 px-2 py-2 xl:px-3 xl:py-3.5">
              <input
                type="checkbox"
                class="zaq-bo-checkbox zaq-focus-visible"
                phx-click="select_all"
                checked={MapSet.size(@selected) > 0 and MapSet.size(@selected) == length(@entries)}
              />
            </th>
            <th class="text-left zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 w-full max-w-0 font-normal">
              Select all
            </th>
          </tr>
        </thead>
      </table>
      <div class="zaq-ingestion-file-grid-cards-wrap min-h-0">
        <div :if={@entries == []} class="py-12 text-center">
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
            Empty directory
          </p>
        </div>

        <div class="zaq-ingestion-file-grid">
          <div
            :for={entry <- @entries}
            class={[
              "group zaq-ingestion-file-grid-card",
              if(MapSet.member?(@selected, record_path(entry)),
                do: "zaq-ingestion-file-grid-card--selected",
                else: ""
              )
            ]}
          >
            <div class={[
              "absolute top-2 left-2 z-10 transition-opacity",
              if(MapSet.member?(@selected, record_path(entry)),
                do: "opacity-100",
                else: "opacity-0 group-hover:opacity-100"
              )
            ]}>
              <input
                type="checkbox"
                class="zaq-bo-checkbox zaq-focus-visible"
                phx-click="toggle_select"
                phx-value-path={record_path(entry)}
                checked={MapSet.member?(@selected, record_path(entry))}
              />
            </div>
            <div class="opacity-0 group-hover:opacity-100 transition-opacity zaq-ingestion-file-grid-card-actions">
              <button
                :if={not @provider_mode}
                phx-click="move_item"
                phx-value-path={record_path(entry)}
                phx-value-type={record_local_type(entry)}
                class="zaq-btn zaq-btn-ghost zaq-btn-icon"
                title="Move to…"
              >
                <svg
                  class="w-3.5 h-3.5"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                  />
                  <path stroke-linecap="round" stroke-linejoin="round" d="M12 11v6m0 0l-2-2m2 2l2-2" />
                </svg>
              </button>
              <button
                :if={not @provider_mode}
                phx-click="rename_item"
                phx-value-path={record_path(entry)}
                phx-value-type={record_local_type(entry)}
                class="zaq-btn zaq-btn-ghost zaq-btn-icon"
                title="Rename"
              >
                <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"
                  />
                </svg>
              </button>
              <button
                :if={
                  not @provider_mode and
                    (record_folder?(entry) or
                       (record_file?(entry) and
                          file_ingestion_status(@ingestion_map, entry.name).can_share?))
                }
                phx-click="share_item"
                phx-value-path={record_path(entry)}
                phx-value-type={record_local_type(entry)}
                class="zaq-btn zaq-btn-ghost zaq-btn-icon"
                title="Share with roles"
              >
                <svg
                  class="w-3.5 h-3.5"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M8.684 13.342C8.886 12.938 9 12.482 9 12c0-.482-.114-.938-.316-1.342m0 2.684a3 3 0 110-2.684m0 2.684l6.632 3.316m-6.632-6l6.632-3.316m0 0a3 3 0 105.367-2.684 3 3 0 00-5.367 2.684zm0 9.316a3 3 0 105.368 2.684 3 3 0 00-5.368-2.684z"
                  />
                </svg>
              </button>
              <button
                :if={not @provider_mode}
                phx-click="delete_item"
                phx-value-path={record_path(entry)}
                phx-value-type={record_local_type(entry)}
                class="zaq-btn zaq-btn-tertiary zaq-btn-danger zaq-btn-icon"
                title="Delete"
              >
                <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                  />
                </svg>
              </button>
            </div>
            <%= if record_folder?(entry) do %>
              <% folder_stats = Map.get(@ingestion_map, entry.name) %>
              <button
                phx-click="navigate"
                phx-value-path={record_path(entry)}
                class="w-full pt-8 pb-3 flex flex-col items-center"
              >
                <img
                  :if={record_icon_url(entry)}
                  src={record_icon_url(entry)}
                  class="w-10 h-10 mb-2 shrink-0"
                  alt=""
                  loading="lazy"
                  decoding="async"
                />
                <svg
                  :if={!record_icon_url(entry)}
                  class="w-10 h-10 mb-2 shrink-0"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                  style="color: var(--zaq-text-color-body-warning)"
                >
                  <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
                </svg>
                <span
                  class="zaq-text-body-sm text-center leading-tight px-2 truncate max-w-full"
                  style="color: var(--zaq-text-color-body-accent)"
                >
                  {entry.name}
                </span>
                <span
                  class="zaq-text-caption mt-0.5 text-center"
                  style="color: var(--zaq-text-color-body-tertiary)"
                >
                  {if folder_stats && folder_stats.total_size > 0,
                    do: SizeFormat.format_size(folder_stats.total_size),
                    else: "—"}
                </span>
                <span
                  :if={folder_stats && folder_stats.file_count > 0}
                  class={[
                    StatusPill.folder_count_pill_classes(
                      folder_stats.ingested_count == folder_stats.file_count
                    ),
                    "mt-1"
                  ]}
                >
                  {folder_stats.ingested_count}/{folder_stats.file_count}
                </span>
              </button>
            <% else %>
              <div
                class="w-full pt-8 pb-3 flex flex-col items-center cursor-pointer"
                role="button"
                tabindex="0"
                phx-click="open_preview"
                phx-value-path={preview_path(entry, @current_volume, @provider_mode)}
              >
                <img
                  :if={record_icon_url(entry)}
                  src={record_icon_url(entry)}
                  class="w-10 h-10 mb-2 shrink-0"
                  alt=""
                  loading="lazy"
                  decoding="async"
                />
                <IngFileIcon.file_icon
                  :if={!record_icon_url(entry)}
                  name={entry.name}
                  class={"w-10 h-10 mb-2 #{file_icon_color(entry.name)}"}
                />
                <span
                  class="zaq-text-body-sm text-center leading-tight px-2 truncate max-w-full"
                  style="color: var(--zaq-text-color-body-default)"
                  title={entry.name}
                >
                  {entry.name}
                </span>
                <span
                  class="zaq-text-caption mt-0.5 text-center"
                  style="color: var(--zaq-text-color-body-tertiary)"
                >
                  {SizeFormat.format_size(entry.size)}
                </span>
                <% status = file_ingestion_status(@ingestion_map, entry.name) %>
                <%= cond do %>
                  <% status.job_status == "processing" -> %>
                    <span class={
                      StatusPill.status_pill_classes("processing") ++
                        ["mt-1", "zaq-pill--pulse"]
                    }>
                      processing
                    </span>
                  <% status.job_status == "pending" -> %>
                    <span class={StatusPill.status_pill_classes("pending") ++ ["mt-1"]}>
                      pending
                    </span>
                  <% status.job_status == "failed" -> %>
                    <span class={StatusPill.status_pill_classes("failed") ++ ["mt-1"]}>
                      failed
                    </span>
                  <% status.stale? -> %>
                    <span class={StatusPill.status_pill_classes("stale") ++ ["mt-1"]}>
                      stale
                    </span>
                  <% status.ingested_at != nil -> %>
                    <div class="flex flex-row flex-wrap items-center justify-center gap-1 mt-1">
                      <span class={StatusPill.status_pill_classes("ingested")}>
                        ingested
                      </span>
                      <.shared_badge
                        provider_mode={@provider_mode}
                        permissions_count={status.permissions_count}
                        path={record_path(entry)}
                      />
                      <span
                        :if={Map.get(status, :is_public, false)}
                        class="zaq-pill zaq-pill--public zaq-text-caption"
                        title="Public"
                      >
                        public
                      </span>
                    </div>
                  <% true -> %>
                    <div class="flex flex-row flex-wrap items-center justify-center gap-1 mt-1">
                      <.shared_badge
                        provider_mode={@provider_mode}
                        permissions_count={status.permissions_count}
                        path={record_path(entry)}
                      />
                      <span
                        :if={Map.get(status, :is_public, false)}
                        class="zaq-pill zaq-pill--public zaq-text-caption"
                        title="Public"
                      >
                        public
                      </span>
                    </div>
                <% end %>
                <button
                  :if={related_record(entry)}
                  type="button"
                  phx-click="open_preview"
                  phx-value-filename={related_record_name(related_record(entry))}
                  phx-value-path={related_record_preview_path(related_record(entry), @current_volume)}
                  class="zaq-table-sidecar-preview zaq-table-sidecar-preview--ingestion-grid"
                  title="Preview converted markdown"
                >
                  <svg
                    class="shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M7 16V4m0 0L3 8m4-4l4 4" />
                  </svg>
                  <IngFileIcon.file_icon
                    name={related_record_name(related_record(entry))}
                    class="w-3.5 h-3.5 shrink-0"
                  />
                  <span class="zaq-table-sidecar-preview-name zaq-text-caption truncate min-w-0">
                    {related_record_name(related_record(entry))}
                  </span>
                  <span
                    class="zaq-table-sidecar-preview-meta zaq-text-caption"
                    style="color: var(--zaq-text-color-body-tertiary)"
                  >
                    {SizeFormat.format_size(related_record_size(related_record(entry)))}
                  </span>
                </button>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
