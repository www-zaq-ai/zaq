defmodule ZaqWeb.Components.DesignSystem.IngestionFileGridView do
  @moduledoc """
  BO ingestion file browser — card grid view.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.IngestionFileIcon, as: IngFileIcon
  import IngFileIcon, only: [file_icon_color: 1]

  alias ZaqWeb.Helpers.SizeFormat

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true

  def file_grid_view(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm max-h-[45vh] overflow-y-scroll p-4">
      <div class="flex items-center gap-2 mb-4 pb-3 border-b border-black/[0.06]">
        <input
          type="checkbox"
          phx-click="select_all"
          checked={MapSet.size(@selected) > 0 and MapSet.size(@selected) == length(@entries)}
          class="rounded border-black/20 zaq-text-accent focus:ring-[var(--zaq-color-accent)]"
        />
        <span class="font-mono text-[0.68rem] text-black/40">Select all</span>
      </div>

      <div :if={@entries == []} class="py-12 text-center">
        <p class="font-mono text-[0.8rem] text-black/30">Empty directory</p>
      </div>

      <div class="grid grid-cols-4 gap-3">
        <div
          :for={entry <- @entries}
          class={[
            "group relative rounded-xl border transition-all cursor-pointer",
            if(MapSet.member?(@selected, Path.join(@current_dir, entry.name)),
              do:
                "border-[var(--zaq-color-accent)] zaq-bg-accent-faint shadow-sm shadow-[var(--zaq-color-accent-border)]",
              else: "border-black/[0.06] hover:border-black/10 hover:shadow-sm"
            )
          ]}
        >
          <div class={[
            "absolute top-2 left-2 z-10 transition-opacity",
            if(MapSet.member?(@selected, Path.join(@current_dir, entry.name)),
              do: "opacity-100",
              else: "opacity-0 group-hover:opacity-100"
            )
          ]}>
            <input
              type="checkbox"
              phx-click="toggle_select"
              phx-value-path={Path.join(@current_dir, entry.name)}
              checked={MapSet.member?(@selected, Path.join(@current_dir, entry.name))}
              class="rounded border-black/20 zaq-text-accent focus:ring-[var(--zaq-color-accent)]"
            />
          </div>
          <div class="absolute top-2 right-2 z-10 opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-0.5">
            <button
              :if={entry.type == :file}
              type="button"
              phx-click="open_preview"
              phx-value-path={Path.join([@current_volume, @current_dir, entry.name])}
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-[var(--zaq-color-accent)] transition-colors"
              title="Preview"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                />
              </svg>
            </button>
            <button
              phx-click="move_item"
              phx-value-path={Path.join(@current_dir, entry.name)}
              phx-value-type={entry.type}
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors cursor-pointer"
              title="Move to…"
            >
              <svg
                class="w-3 h-3"
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
              phx-click="rename_item"
              phx-value-path={Path.join(@current_dir, entry.name)}
              phx-value-type={entry.type}
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors cursor-pointer"
              title="Rename"
            >
              <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
                entry.type == :directory or
                  (entry.type == :file and
                     Map.get(@ingestion_map, entry.name, %{can_share?: false}).can_share?)
              }
              phx-click="share_item"
              phx-value-path={Path.join(@current_dir, entry.name)}
              phx-value-type={entry.type}
              class="p-1 hover:bg-[var(--zaq-color-accent-soft)] rounded-lg text-black/30 hover:text-[var(--zaq-color-accent)] transition-colors cursor-pointer"
              title="Share with roles"
            >
              <svg
                class="w-3 h-3"
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
              phx-value-path={Path.join(@current_dir, entry.name)}
              phx-value-type={entry.type}
              class="p-1 hover:bg-red-500/10 rounded-lg text-black/30 hover:text-red-500 transition-colors cursor-pointer"
              title="Delete"
            >
              <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </button>
          </div>
          <%= if entry.type == :directory do %>
            <% folder_stats = Map.get(@ingestion_map, entry.name) %>
            <button
              phx-click="navigate"
              phx-value-path={Path.join(@current_dir, entry.name)}
              class="w-full pt-8 pb-3 flex flex-col items-center"
            >
              <svg class="w-10 h-10 text-amber-400 mb-2" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
              <span class="font-mono text-[0.75rem] zaq-text-accent text-center leading-tight px-2 truncate max-w-full">
                {entry.name}
              </span>
              <span class="font-mono text-[0.6rem] text-black/30 mt-0.5">
                {if folder_stats && folder_stats.total_size > 0,
                  do: SizeFormat.format_size(folder_stats.total_size),
                  else: "—"}
              </span>
              <span
                :if={folder_stats && folder_stats.file_count > 0}
                class={[
                  "font-mono text-[0.55rem] px-1.5 py-0.5 rounded mt-1",
                  if(folder_stats.ingested_count == folder_stats.file_count,
                    do: "bg-emerald-100 text-emerald-700",
                    else: "bg-amber-100 text-amber-600"
                  )
                ]}
              >
                {folder_stats.ingested_count}/{folder_stats.file_count}
              </span>
            </button>
          <% else %>
            <button
              type="button"
              phx-click="open_preview"
              phx-value-path={Path.join([@current_volume, @current_dir, entry.name])}
              class="w-full pt-8 pb-3 flex flex-col items-center cursor-pointer"
            >
              <IngFileIcon.file_icon
                name={entry.name}
                class={"w-10 h-10 mb-2 #{file_icon_color(entry.name)}"}
              />
              <span
                class="font-mono text-[0.75rem] text-black text-center leading-tight px-2 truncate max-w-full"
                title={entry.name}
              >
                {entry.name}
              </span>
              <span class="font-mono text-[0.6rem] text-black/30 mt-0.5">
                {SizeFormat.format_size(entry.size)}
              </span>
              <% status =
                Map.get(@ingestion_map, entry.name, %{
                  ingested_at: nil,
                  stale?: false,
                  job_status: nil
                }) %>
              <%= cond do %>
                <% status.job_status == "processing" -> %>
                  <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-amber-100 text-amber-600 mt-1 animate-pulse">
                    processing
                  </span>
                <% status.job_status == "pending" -> %>
                  <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-black/5 text-black/40 mt-1">
                    pending
                  </span>
                <% status.job_status == "failed" -> %>
                  <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-red-100 text-red-600 mt-1">
                    failed
                  </span>
                <% status.stale? -> %>
                  <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-amber-100 text-amber-600 mt-1">
                    stale
                  </span>
                <% status.ingested_at != nil -> %>
                  <div class="flex flex-row flex-wrap items-center justify-center gap-1 mt-1">
                    <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">
                      ingested
                    </span>
                    <span
                      :if={status.permissions_count > 0}
                      class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded zaq-bg-accent-soft zaq-text-accent"
                      title={"Shared with #{status.permissions_count} person(s)/team(s)"}
                    >
                      shared
                    </span>
                    <span
                      :if={Map.get(status, :is_public, false)}
                      class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-violet-100 text-violet-600"
                      title="Public"
                    >
                      public
                    </span>
                  </div>
                <% true -> %>
                  <div class="flex flex-row flex-wrap items-center justify-center gap-1 mt-1">
                    <span
                      :if={status.permissions_count > 0}
                      class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded zaq-bg-accent-soft zaq-text-accent"
                      title={"Shared with #{status.permissions_count} person(s)/team(s)"}
                    >
                      shared
                    </span>
                    <span
                      :if={Map.get(status, :is_public, false)}
                      class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-violet-100 text-violet-600"
                      title="Public"
                    >
                      public
                    </span>
                  </div>
              <% end %>
              <button
                :if={Map.get(entry, :related_md)}
                type="button"
                phx-click="open_preview"
                phx-value-path={
                  Path.join([
                    @current_volume,
                    @current_dir,
                    Map.get(entry, :related_md, %{name: ""}).name
                  ])
                }
                class="mt-2 flex items-center gap-1 font-mono text-[0.6rem] zaq-text-accent opacity-50 hover:text-[var(--zaq-color-accent)] hover:underline transition-colors border-t border-dashed border-black/[0.06] pt-2 w-full justify-center cursor-pointer"
                title="Preview converted markdown"
              >
                <IngFileIcon.file_icon
                  name={Map.get(entry, :related_md, %{name: ""}).name}
                  class="w-3 h-3"
                /> md preview
              </button>
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
