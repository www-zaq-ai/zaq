defmodule ZaqWeb.Components.DesignSystem.IngestionFileListView do
  @moduledoc """
  BO ingestion file browser — table (list) view via `DesignSystem.Table`.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Table,
    only: [
      table: 1,
      table_actions: 1,
      table_badge: 1,
      table_cell: 1,
      table_checkbox: 1,
      table_datetime: 1,
      table_empty: 1,
      table_head_row: 1,
      table_row: 1,
      table_sidecar_row: 1,
      table_text: 1
    ]

  import ZaqWeb.Components.DesignSystem.IngestionFileIcon, only: [file_icon: 1]

  import ZaqWeb.Components.DesignSystem.IngestionFileStatus
  import ZaqWeb.Helpers.DateFormat, only: [format_datetime: 1]

  alias ZaqWeb.Components.DesignSystem.IngestionFileIcon, as: IngFileIcon
  alias ZaqWeb.Helpers.SizeFormat

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :provider_mode, :boolean, default: false

  def file_list_view(assigns) do
    ~H"""
    <.table
      id="ingestion-file-list"
      scrollable={true}
      class="min-w-[700px] xl:min-w-0"
    >
      <:head>
        <.table_head_row sticky_header={true}>
          <.table_cell element={:th} width="w-6" class="xl:px-3">
            <.table_checkbox
              phx-click="select_all"
              checked={MapSet.size(@selected) > 0 and MapSet.size(@selected) == length(@entries)}
            />
          </.table_cell>
          <.table_cell element={:th} class="zaq-ingestion-meta-label w-full max-w-0">
            <.table_text label="Name" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th} width="w-24" nowrap class="zaq-ingestion-meta-label">
            <.table_text label="Size" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th} width="w-36" class="zaq-ingestion-meta-label">
            <.table_text label="Status" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th} width="w-28" nowrap class="zaq-ingestion-meta-label">
            <.table_text label="Access" tone={:tertiary} />
          </.table_cell>
          <.table_cell element={:th} align={:right} nowrap class="zaq-ingestion-meta-label">
            <.table_text label="Modified" tone={:tertiary} />
          </.table_cell>
        </.table_head_row>
      </:head>
      <:body>
        <.table_empty :if={@entries == []} colspan={6}>
          <span style="color: var(--zaq-text-color-body-tertiary)">Empty directory</span>
        </.table_empty>
        <%= for entry <- @entries do %>
          <.table_row variant={
            if(MapSet.member?(@selected, record_path(entry)), do: :selected, else: :default)
          }>
            <.table_cell width="w-6" class="xl:px-3">
              <.table_checkbox
                phx-click="toggle_select"
                phx-value-path={record_path(entry)}
                checked={MapSet.member?(@selected, record_path(entry))}
              />
            </.table_cell>
            <.table_cell class="max-w-0 w-full">
              <div class="flex items-center justify-between gap-3 min-w-0">
                <%= if record_folder?(entry) do %>
                  <button
                    phx-click="navigate"
                    phx-value-path={record_path(entry)}
                    class="flex items-center gap-2 min-w-0 zaq-text-body zaq-link-underline text-left cursor-pointer"
                    style="color: var(--zaq-text-color-body-accent)"
                    title={entry.name}
                  >
                    <img
                      :if={record_icon_url(entry)}
                      src={record_icon_url(entry)}
                      class="w-4 h-4 shrink-0"
                      alt=""
                      loading="lazy"
                      decoding="async"
                    />
                    <svg
                      :if={!record_icon_url(entry)}
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
                    phx-value-path={preview_path(entry, @current_volume, @provider_mode)}
                    class="flex items-center gap-2 min-w-0 text-left cursor-pointer zaq-text-body zaq-link-underline zaq-table-preview-link"
                    title={entry.name}
                  >
                    <img
                      :if={record_icon_url(entry)}
                      src={record_icon_url(entry)}
                      class="w-4 h-4 shrink-0"
                      alt=""
                      loading="lazy"
                      decoding="async"
                    />
                    <.file_icon
                      :if={!record_icon_url(entry)}
                      name={entry.name}
                      class={"w-4 h-4 shrink-0 #{IngFileIcon.file_icon_color(entry.name)}"}
                    />
                    <span class="truncate">{entry.name}</span>
                  </button>
                <% end %>
                <.table_actions reveal={:hover}>
                  <.entry_row_actions
                    entry={entry}
                    provider_mode={@provider_mode}
                    ingestion_map={@ingestion_map}
                  />
                </.table_actions>
              </div>
            </.table_cell>
            <.table_cell width="w-24" nowrap>
              <.table_text
                label={entry_size_label(entry, @ingestion_map)}
                tone={:tertiary}
              />
            </.table_cell>
            <.table_cell width="w-36">
              <.entry_status_cell entry={entry} ingestion_map={@ingestion_map} />
            </.table_cell>
            <.table_cell width="w-28">
              <.entry_access_cell
                entry={entry}
                ingestion_map={@ingestion_map}
                provider_mode={@provider_mode}
              />
            </.table_cell>
            <.table_cell align={:right} nowrap>
              <.table_datetime value={entry.modified_at} align={:right} />
            </.table_cell>
          </.table_row>
          <.table_sidecar_row
            :if={related_record(entry)}
            leading_colspan={1}
            body_colspan={5}
          >
            <button
              type="button"
              phx-click="open_preview"
              phx-value-filename={related_record_name(related_record(entry))}
              phx-value-path={related_record_preview_path(related_record(entry), @current_volume)}
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
          </.table_sidecar_row>
        <% end %>
      </:body>
    </.table>
    """
  end

  attr :entry, :map, required: true
  attr :provider_mode, :boolean, required: true
  attr :ingestion_map, :map, required: true

  defp entry_row_actions(assigns) do
    ~H"""
    <button
      :if={not @provider_mode}
      phx-click="move_item"
      phx-value-path={record_path(@entry)}
      phx-value-type={record_local_type(@entry)}
      class="zaq-btn zaq-btn-ghost zaq-btn-icon"
      title="Move to…"
    >
      <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
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
      phx-value-path={record_path(@entry)}
      phx-value-type={record_local_type(@entry)}
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
      :if={shareable?(@entry, @provider_mode, @ingestion_map)}
      phx-click="share_item"
      phx-value-path={record_path(@entry)}
      phx-value-type={record_local_type(@entry)}
      class="zaq-btn zaq-btn-ghost zaq-btn-icon"
      title="Share with roles"
    >
      <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
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
      phx-value-path={record_path(@entry)}
      phx-value-type={record_local_type(@entry)}
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
    """
  end

  attr :entry, :map, required: true
  attr :ingestion_map, :map, required: true

  defp entry_status_cell(assigns) do
    ~H"""
    <%= if record_file?(@entry) do %>
      <% status = file_ingestion_status(@ingestion_map, @entry.name) %>
      <%= cond do %>
        <% status.job_status == "processing" -> %>
          <.table_badge status="processing" pulse />
        <% status.job_status == "pending" -> %>
          <.table_badge status="pending" />
        <% status.job_status == "failed" -> %>
          <.table_badge status="failed" />
        <% status.stale? -> %>
          <div class="flex flex-col gap-0.5">
            <.table_badge status="stale">
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
            </.table_badge>
            <span class="font-mono text-[0.6rem] text-black/30 whitespace-nowrap">
              {format_datetime(status.ingested_at)}
            </span>
          </div>
        <% status.ingested_at != nil -> %>
          <div class="flex flex-col gap-0.5">
            <.table_badge status="ingested">
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
            </.table_badge>
            <span class="font-mono text-[0.6rem] text-black/30 whitespace-nowrap">
              {format_datetime(status.ingested_at)}
            </span>
          </div>
        <% true -> %>
          <span class="font-mono text-[0.65rem] text-black/20">—</span>
      <% end %>
    <% else %>
      <% folder_stats = Map.get(@ingestion_map, @entry.name) %>
      <%= cond do %>
        <% folder_stats && folder_stats.file_count > 0 && folder_stats.ingested_count == folder_stats.file_count -> %>
          <span class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-success)">
            {folder_stats.file_count}/{folder_stats.file_count}
          </span>
        <% folder_stats && folder_stats.ingested_count > 0 -> %>
          <span class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-warning)">
            {folder_stats.ingested_count}/{folder_stats.file_count}
          </span>
        <% true -> %>
          <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
            —
          </span>
      <% end %>
    <% end %>
    """
  end

  attr :entry, :map, required: true
  attr :ingestion_map, :map, required: true
  attr :provider_mode, :boolean, required: true

  defp entry_access_cell(assigns) do
    ~H"""
    <%= if record_file?(@entry) do %>
      <% status = file_ingestion_status(@ingestion_map, @entry.name) %>
      <div class="flex items-center gap-1 flex-wrap">
        <.shared_badge
          provider_mode={@provider_mode}
          permissions_count={status.permissions_count}
          path={record_path(@entry)}
          icon
        />
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
      <% folder_stats = Map.get(@ingestion_map, @entry.name) %>
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
    """
  end

  defp entry_size_label(entry, ingestion_map) do
    if record_file?(entry) do
      SizeFormat.format_size(entry.size)
    else
      case Map.get(ingestion_map, entry.name) do
        %{total_size: size} when size > 0 -> SizeFormat.format_size(size)
        _ -> "—"
      end
    end
  end

  defp shareable?(entry, provider_mode, ingestion_map) do
    not provider_mode and
      (record_folder?(entry) or
         (record_file?(entry) and
            Map.get(ingestion_map, entry.name, %{can_share?: false}).can_share?))
  end
end
