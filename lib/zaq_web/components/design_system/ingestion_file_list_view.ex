defmodule ZaqWeb.Components.DesignSystem.IngestionFileListView do
  @moduledoc """
  BO ingestion file browser — table (list) view.
  """

  use Phoenix.Component

  import ZaqWeb.Helpers.DateFormat

  alias ZaqWeb.Components.DesignSystem.IngestionFileIcon, as: IngFileIcon
  import IngFileIcon, only: [file_icon: 1]

  import ZaqWeb.Components.DesignSystem.IngestionFileStatus

  alias ZaqWeb.Components.DesignSystem.StatusPill
  alias ZaqWeb.Helpers.SizeFormat

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true

  def file_list_view(assigns) do
    ~H"""
    <div class="max-h-[45vh] overflow-y-scroll overflow-x-auto">
      <table class="zaq-table zaq-border-default w-full min-w-[700px] xl:min-w-0">
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
            <th class="text-left zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 w-full max-w-0">
              Name
            </th>
            <th class="text-left zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 w-24 whitespace-nowrap">
              Size
            </th>
            <th class="text-left zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 w-36">
              Status
            </th>
            <th class="text-left zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 w-28 whitespace-nowrap">
              Access
            </th>
            <th class="text-right zaq-ingestion-meta-label zaq-text-caption px-2 py-2 xl:px-4 xl:py-3.5 whitespace-nowrap">
              Modified
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@entries == []} class="zaq-table-row--plain">
            <td
              colspan="6"
              class="px-4 py-8 text-center zaq-text-body-sm"
              style="color: var(--zaq-text-color-body-tertiary)"
            >
              Empty directory
            </td>
          </tr>
          <%= for entry <- @entries do %>
            <tr class="group transition-colors">
              <td class="px-2 py-2 xl:px-3 xl:py-3 w-6">
                <input
                  type="checkbox"
                  class="zaq-bo-checkbox zaq-focus-visible"
                  phx-click="toggle_select"
                  phx-value-path={record_path(entry)}
                  checked={MapSet.member?(@selected, record_path(entry))}
                />
              </td>
              <td class="px-2 py-2 xl:px-4 xl:py-3 max-w-0 w-full">
                <div class="flex items-center justify-between">
                  <%= if record_folder?(entry) do %>
                    <button
                      phx-click="navigate"
                      phx-value-path={record_path(entry)}
                      class="flex items-center gap-2 min-w-0 zaq-text-body zaq-link-underline text-left cursor-pointer"
                      style="color: var(--zaq-text-color-body-accent)"
                      title={entry.name}
                    >
                      <svg
                        class="w-4 h-4 shrink-0"
                        fill="currentColor"
                        viewBox="0 0 20 20"
                        style="color: var(--zaq-text-color-body-warning)"
                      >
                        <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
                      </svg>
                      <span class="truncate">{entry.name}</span>
                    </button>
                  <% else %>
                    <button
                      type="button"
                      phx-click="open_preview"
                      phx-value-path={Path.join([@current_volume, record_path(entry)])}
                      class="flex items-center gap-2 min-w-0 text-left cursor-pointer zaq-text-body zaq-link-underline zaq-table-preview-link"
                      title={entry.name}
                    >
                      <.file_icon
                        name={entry.name}
                        class={"w-4 h-4 shrink-0 #{IngFileIcon.file_icon_color(entry.name)}"}
                      />
                      <span class="truncate">{entry.name}</span>
                    </button>
                  <% end %>
                  <div class="opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-1 ml-3 shrink-0">
                    <button
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
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M12 11v6m0 0l-2-2m2 2l2-2"
                        />
                      </svg>
                    </button>
                    <button
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
                        record_folder?(entry) or
                          (record_file?(entry) and
                             Map.get(@ingestion_map, entry.name, %{can_share?: false}).can_share?)
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
                </div>
              </td>
              <td
                class="zaq-text-body-sm px-2 py-2 xl:px-4 xl:py-3 w-24 whitespace-nowrap"
                style="color: var(--zaq-text-color-body-tertiary)"
              >
                <%= if record_file?(entry) do %>
                  {SizeFormat.format_size(entry.size)}
                <% else %>
                  <% folder_stats = Map.get(@ingestion_map, entry.name) %>
                  {if folder_stats && folder_stats.total_size > 0,
                    do: SizeFormat.format_size(folder_stats.total_size),
                    else: "—"}
                <% end %>
              </td>
              <%!-- Status column: ingestion state only --%>
              <td class="px-2 py-2 xl:px-4 xl:py-3">
                <%= if record_file?(entry) do %>
                  <% status = file_ingestion_status(@ingestion_map, entry.name) %>
                  <%= cond do %>
                    <% status.job_status == "processing" -> %>
                      <span class={
                        StatusPill.status_pill_classes("processing") ++ ["zaq-pill--pulse"]
                      }>
                        processing
                      </span>
                    <% status.job_status == "pending" -> %>
                      <span class={StatusPill.status_pill_classes("pending")}>
                        pending
                      </span>
                    <% status.job_status == "failed" -> %>
                      <span class={StatusPill.status_pill_classes("failed")}>
                        failed
                      </span>
                    <% status.stale? -> %>
                      <div class="flex flex-col gap-0.5">
                        <span class={StatusPill.status_pill_classes("stale")}>
                          <svg
                            class="w-3 h-3 shrink-0"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="2"
                            viewBox="0 0 24 24"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                            />
                          </svg>
                          stale
                        </span>
                        <span class="font-mono text-[0.6rem] text-black/30 whitespace-nowrap">
                          {format_datetime(status.ingested_at)}
                        </span>
                      </div>
                    <% status.ingested_at != nil -> %>
                      <div class="flex flex-col gap-0.5">
                        <span class={StatusPill.status_pill_classes("ingested")}>
                          <svg
                            class="w-3 h-3 shrink-0"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="2"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                          ingested
                        </span>
                        <span class="font-mono text-[0.6rem] text-black/30 whitespace-nowrap">
                          {format_datetime(status.ingested_at)}
                        </span>
                      </div>
                    <% true -> %>
                      <span class="font-mono text-[0.65rem] text-black/20">—</span>
                  <% end %>
                <% else %>
                  <% folder_stats = Map.get(@ingestion_map, entry.name) %>
                  <%= cond do %>
                    <% folder_stats && folder_stats.file_count > 0 && folder_stats.ingested_count == folder_stats.file_count -> %>
                      <span
                        class="zaq-text-body-sm"
                        style="color: var(--zaq-text-color-body-success)"
                      >
                        {folder_stats.file_count}/{folder_stats.file_count}
                      </span>
                    <% folder_stats && folder_stats.ingested_count > 0 -> %>
                      <span
                        class="zaq-text-body-sm"
                        style="color: var(--zaq-text-color-body-warning)"
                      >
                        {folder_stats.ingested_count}/{folder_stats.file_count}
                      </span>
                    <% true -> %>
                      <span
                        class="zaq-text-caption"
                        style="color: var(--zaq-text-color-body-tertiary)"
                      >
                        —
                      </span>
                  <% end %>
                <% end %>
              </td>
              <%!-- Access column: shared / public badges --%>
              <td class="px-2 py-2 xl:px-4 xl:py-3 w-28">
                <%= if record_file?(entry) do %>
                  <% status = file_ingestion_status(@ingestion_map, entry.name) %>
                  <div class="flex items-center gap-1 flex-wrap">
                    <span
                      :if={status.permissions_count > 0}
                      class="zaq-pill zaq-pill--shared zaq-text-caption"
                      title={"Shared with #{status.permissions_count} person(s)/team(s)"}
                    >
                      <svg
                        class="w-3 h-3 shrink-0"
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
                      shared
                    </span>
                    <span
                      :if={Map.get(status, :is_public, false)}
                      class="zaq-pill zaq-pill--public zaq-text-caption cursor-default"
                      title="Public — accessible to all authenticated users"
                    >
                      <svg
                        class="w-3 h-3 shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                      >
                        <circle cx="12" cy="12" r="10" /><path
                          stroke-linecap="round"
                          d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"
                        />
                      </svg>
                      public
                    </span>
                  </div>
                <% else %>
                  <% folder_stats = Map.get(@ingestion_map, entry.name) %>
                  <span
                    :if={folder_stats && Map.get(folder_stats, :is_public, false)}
                    class="zaq-pill zaq-pill--public zaq-text-caption cursor-default"
                    title="Public — all files in this folder are accessible to all authenticated users"
                  >
                    <svg
                      class="w-3 h-3 shrink-0"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      viewBox="0 0 24 24"
                    >
                      <circle cx="12" cy="12" r="10" /><path
                        stroke-linecap="round"
                        d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"
                      />
                    </svg>
                    public
                  </span>
                <% end %>
              </td>
              <td
                class="zaq-text-body-sm px-2 py-2 xl:px-4 xl:py-3 text-right whitespace-nowrap"
                style="color: var(--zaq-text-color-body-tertiary)"
              >
                {format_datetime(entry.modified_at)}
              </td>
            </tr>
            <tr
              :if={related_record(entry)}
              class="zaq-table-row--sidecar"
            >
              <td></td>
              <td class="px-4 py-1.5 overflow-hidden max-w-0" colspan="5">
                <button
                  type="button"
                  phx-click="open_preview"
                  phx-value-path={
                    Path.join([
                      @current_volume,
                      related_record_path(related_record(entry))
                    ])
                  }
                  class="zaq-table-sidecar-preview"
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
                  <.file_icon
                    name={related_record_name(related_record(entry))}
                    class="w-3.5 h-3.5 zaq-text-accent"
                  />
                  <span class="zaq-table-sidecar-preview-name zaq-text-body truncate min-w-0">
                    {related_record_name(related_record(entry))}
                  </span>
                  <span
                    class="zaq-table-sidecar-preview-meta zaq-text-caption"
                    style="color: var(--zaq-text-color-body-tertiary)"
                  >
                    {SizeFormat.format_size(related_record_size(related_record(entry)))}
                  </span>
                </button>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end
end
