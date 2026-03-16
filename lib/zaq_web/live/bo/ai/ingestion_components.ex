# lib/zaq_web/live/bo/ai/ingestion_components.ex

defmodule ZaqWeb.Live.BO.AI.IngestionComponents do
  @moduledoc """
  Function components for the Ingestion LiveView.
  """

  use Phoenix.Component
  use ZaqWeb, :verified_routes

  import ZaqWeb.Helpers.DateFormat

  # ── Helpers ──────────────────────────────────────────────────────────────

  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @doc "Renders a file-type icon based on the file extension."
  attr :name, :string, required: true
  attr :class, :string, default: "w-4 h-4"

  def file_icon(%{name: name} = assigns) do
    assigns = assign(assigns, :ext, Path.extname(name) |> String.downcase())

    ~H"""
    <%= cond do %>
      <% @ext == ".pdf" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#FEE2E2"
            stroke="#DC2626"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#DC2626" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#DC2626" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="20"
          >
            PDF
          </text>
        </svg>
      <% @ext == ".docx" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#EFF6FF"
            stroke="#2563EB"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#2563EB" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#2563EB" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="17"
          >
            DOCX
          </text>
        </svg>
      <% @ext in [".xlsx", ".xls"] -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#F0FDF4"
            stroke="#16A34A"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#16A34A" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#16A34A" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="17"
          >
            XLSX
          </text>
        </svg>
      <% @ext == ".csv" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#ECFDF5"
            stroke="#059669"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#059669" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#059669" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="20"
          >
            CSV
          </text>
        </svg>
      <% @ext == ".md" -> %>
        <svg class={@class} viewBox="0 0 80 100" fill="none" xmlns="http://www.w3.org/2000/svg">
          <path
            d="M6 0 L52 0 L78 26 L78 94 Q78 100 72 100 L6 100 Q0 100 0 94 L0 6 Q0 0 6 0 Z"
            fill="#ECFEFF"
            stroke="#0891B2"
            stroke-width="3.5"
          />
          <path d="M52 0 L78 26 L52 26 Z" fill="#0891B2" />
          <rect x="4" y="58" width="72" height="28" rx="5" fill="#0891B2" />
          <text
            x="40"
            y="72"
            text-anchor="middle"
            dominant-baseline="central"
            fill="white"
            font-family="Arial, sans-serif"
            font-weight="700"
            font-size="22"
          >
            MD
          </text>
        </svg>
      <% true -> %>
        <%!-- Generic document icon --%>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
          <polyline points="14 2 14 8 20 8" />
        </svg>
    <% end %>
    """
  end

  defp file_icon_color(name) do
    case Path.extname(name) |> String.downcase() do
      ".pdf" -> "text-red-400"
      ".md" -> "text-[#03b6d4]"
      ".xlsx" -> "text-emerald-500"
      ".csv" -> "text-emerald-400"
      ".docx" -> "text-blue-400"
      _ -> "text-black/30"
    end
  end

  def status_color("pending"), do: "bg-black/5 text-black/40"
  def status_color("processing"), do: "bg-amber-100 text-amber-600"
  def status_color("completed"), do: "bg-emerald-100 text-emerald-700"
  def status_color("failed"), do: "bg-red-100 text-red-600"
  def status_color(_), do: "bg-black/5 text-black/30"

  # ── Volume Selector ───────────────────────────────────────────────────────

  attr :volumes, :map, required: true
  attr :current_volume, :string, required: true

  def volume_selector(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider shrink-0">
        Volume
      </p>
      <div class="flex items-center gap-1 flex-wrap">
        <button
          :for={{name, _path} <- Enum.sort(@volumes)}
          phx-click="switch_volume"
          phx-value-volume={name}
          class={[
            "font-mono text-[0.7rem] px-2.5 py-1 rounded-lg transition-colors",
            if(@current_volume == name,
              do: "bg-[#03b6d4] text-white",
              else: "bg-black/5 text-black/40 hover:bg-black/10"
            )
          ]}
        >
          {name}
        </button>
      </div>
    </div>
    """
  end

  # ── File Browser Header ───────────────────────────────────────────────────

  attr :selected, :any, required: true
  attr :ingest_mode, :string, required: true

  def file_browser_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-3">
      <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">
        File Browser
      </p>
      <div class="flex items-center gap-2">
        <button
          phx-click="show_new_folder_modal"
          class="font-mono text-[0.7rem] px-2.5 py-1 rounded-lg bg-black/5 text-black/40 hover:bg-black/10 transition-colors flex items-center gap-1"
        >
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Folder
        </button>
        <button
          phx-click="show_add_raw_modal"
          class="font-mono text-[0.7rem] px-2.5 py-1 rounded-lg bg-black/5 text-black/40 hover:bg-black/10 transition-colors flex items-center gap-1"
        >
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
            />
          </svg>
          Add Raw MD
        </button>
        <button
          :if={MapSet.size(@selected) > 0}
          phx-click="show_delete_confirmation"
          class="font-mono text-[0.7rem] px-2.5 py-1 rounded-lg bg-red-500/10 text-red-500 hover:bg-red-500/20 transition-colors flex items-center gap-1"
        >
          <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
            />
          </svg>
          Delete ({MapSet.size(@selected)})
        </button>
        <button
          :for={mode <- ~w(async inline)}
          phx-click="set_mode"
          phx-value-mode={mode}
          class={[
            "font-mono text-[0.7rem] px-2.5 py-1 rounded-lg transition-colors",
            if(@ingest_mode == mode,
              do: "bg-[#03b6d4] text-white",
              else: "bg-black/5 text-black/40 hover:bg-black/10"
            )
          ]}
        >
          {mode}
        </button>
        <button
          phx-click="ingest_selected"
          disabled={MapSet.size(@selected) == 0}
          class={[
            "font-mono text-[0.78rem] font-bold px-4 py-1.5 rounded-lg transition-all",
            if(MapSet.size(@selected) > 0,
              do: "bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20",
              else: "bg-black/5 text-black/20 cursor-not-allowed"
            )
          ]}
        >
          Ingest Selected ({MapSet.size(@selected)})
        </button>
      </div>
    </div>
    """
  end

  # ── Breadcrumbs ───────────────────────────────────────────────────────────

  attr :breadcrumbs, :list, required: true
  attr :current_dir, :string, required: true

  def breadcrumbs(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5 mb-3 font-mono text-[0.75rem]">
      <button
        :if={@current_dir != "."}
        phx-click="go_back"
        class="flex items-center justify-center w-6 h-6 rounded-lg bg-black/5 text-black/40 hover:bg-black/10 hover:text-black/60 transition-colors shrink-0 mr-1"
        title="Go back"
      >
        <svg
          class="w-3.5 h-3.5"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
        </svg>
      </button>
      <button phx-click="navigate" phx-value-path="." class="text-[#03b6d4] hover:underline">
        root
      </button>
      <span :for={crumb <- @breadcrumbs} class="flex items-center gap-1">
        <span class="text-black/20">/</span>
        <button
          phx-click="navigate"
          phx-value-path={crumb.path}
          class="text-[#03b6d4] hover:underline"
        >
          {crumb.name}
        </button>
      </span>
    </div>
    """
  end

  # ── View Mode Toggle ──────────────────────────────────────────────────────

  attr :view_mode, :string, required: true
  attr :entries, :list, required: true

  def view_mode_toggle(assigns) do
    ~H"""
    <div class="flex items-center gap-1 mb-3">
      <div class="flex items-center bg-black/5 rounded-lg p-0.5">
        <button
          phx-click="toggle_view_mode"
          phx-value-mode="list"
          class={[
            "p-1.5 rounded-md transition-colors",
            if(@view_mode == "list",
              do: "bg-white text-black/70 shadow-sm",
              else: "text-black/30 hover:text-black/50"
            )
          ]}
          title="List view"
        >
          <svg
            class="w-3.5 h-3.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16" />
          </svg>
        </button>
        <button
          phx-click="toggle_view_mode"
          phx-value-mode="grid"
          class={[
            "p-1.5 rounded-md transition-colors",
            if(@view_mode == "grid",
              do: "bg-white text-black/70 shadow-sm",
              else: "text-black/30 hover:text-black/50"
            )
          ]}
          title="Grid view"
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
              d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zm10 0a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zm10 0a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"
            />
          </svg>
        </button>
      </div>
      <span class="font-mono text-[0.68rem] text-black/25 ml-1">{length(@entries)} item(s)</span>
    </div>
    """
  end

  # ── File List View ────────────────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :all_roles, :list, default: []

  def file_list_view(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm max-h-[45vh] overflow-y-scroll">
      <table class="w-full">
        <thead>
          <tr class="border-b border-black/[0.06] bg-[#fafafa]">
            <th class="w-10 px-4 py-3.5">
              <input
                type="checkbox"
                phx-click="select_all"
                checked={MapSet.size(@selected) > 0 and MapSet.size(@selected) == length(@entries)}
                class="rounded border-black/20 text-[#03b6d4] focus:ring-[#03b6d4]"
              />
            </th>
            <th class="text-left font-mono text-[0.68rem] font-semibold text-black/40 uppercase tracking-wider px-4 py-3.5">
              Name
            </th>
            <th class="text-left font-mono text-[0.68rem] font-semibold text-black/40 uppercase tracking-wider px-4 py-3.5">
              Size
            </th>
            <th class="text-left font-mono text-[0.68rem] font-semibold text-black/40 uppercase tracking-wider px-4 py-3.5">
              Status
            </th>
            <th class="text-right font-mono text-[0.68rem] font-semibold text-black/40 uppercase tracking-wider px-4 py-3.5">
              Modified
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@entries == []} class="border-b border-black/[0.04]">
            <td colspan="5" class="px-4 py-8 text-center font-mono text-[0.8rem] text-black/30">
              Empty directory
            </td>
          </tr>
          <%= for entry <- @entries do %>
            <tr class="border-b border-black/[0.04] last:border-0 hover:bg-black/[0.015] transition-colors group">
              <td class="px-4 py-3 w-10">
                <input
                  type="checkbox"
                  phx-click="toggle_select"
                  phx-value-path={Path.join(@current_dir, entry.name)}
                  checked={MapSet.member?(@selected, Path.join(@current_dir, entry.name))}
                  class="rounded border-black/20 text-[#03b6d4] focus:ring-[#03b6d4]"
                />
              </td>
              <td class="px-4 py-3">
                <div class="flex items-center justify-between">
                  <%= if entry.type == :directory do %>
                    <button
                      phx-click="navigate"
                      phx-value-path={Path.join(@current_dir, entry.name)}
                      class="flex items-center gap-2 font-mono text-[0.85rem] text-[#03b6d4] hover:underline"
                    >
                      <svg class="w-4 h-4 text-amber-500" fill="currentColor" viewBox="0 0 20 20">
                        <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
                      </svg>
                      {entry.name}
                    </button>
                  <% else %>
                    <span class="flex items-center gap-2 font-mono text-[0.85rem] text-black">
                      <.file_icon name={entry.name} class={"w-4 h-4 #{file_icon_color(entry.name)}"} />
                      {entry.name}
                    </span>
                  <% end %>
                  <div class="opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-1 ml-3 shrink-0">
                    <a
                      :if={entry.type == :file}
                      href={"/bo/preview/#{Path.join(@current_dir, entry.name)}"}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="p-1.5 hover:bg-black/5 rounded-lg text-black/30 hover:text-[#03b6d4] transition-colors"
                      title="Preview in new tab"
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
                          d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
                        />
                      </svg>
                    </a>
                    <button
                      phx-click="move_item"
                      phx-value-path={Path.join(@current_dir, entry.name)}
                      phx-value-type={entry.type}
                      class="p-1.5 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors"
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
                      phx-value-path={Path.join(@current_dir, entry.name)}
                      phx-value-type={entry.type}
                      class="p-1.5 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors"
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
                      :if={entry.type == :file}
                      phx-click="share_item"
                      phx-value-path={Path.join(@current_dir, entry.name)}
                      class="p-1.5 hover:bg-[#03b6d4]/10 rounded-lg text-black/30 hover:text-[#03b6d4] transition-colors"
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
                      phx-value-path={Path.join(@current_dir, entry.name)}
                      phx-value-type={entry.type}
                      class="p-1.5 hover:bg-red-500/10 rounded-lg text-black/30 hover:text-red-500 transition-colors"
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
              <td class="font-mono text-[0.78rem] text-black/40 px-4 py-3">
                {if entry.type == :file, do: format_size(entry.size), else: "—"}
              </td>
              <td class="px-4 py-3">
                <%= if entry.type == :file do %>
                  <% status = Map.get(@ingestion_map, entry.name, %{ingested_at: nil, stale?: false}) %>
                  <%= cond do %>
                    <% status.stale? -> %>
                      <div class="flex flex-col gap-0.5">
                        <span class="inline-flex items-center gap-1 font-mono text-[0.65rem] px-2 py-0.5 rounded bg-amber-100 text-amber-600 w-fit">
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
                              d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                            />
                          </svg>
                          stale
                        </span>
                        <span class="font-mono text-[0.6rem] text-black/30">
                          {format_datetime(status.ingested_at)}
                        </span>
                      </div>
                    <% status.ingested_at != nil -> %>
                      <div class="flex flex-col gap-0.5">
                        <div class="flex items-center gap-1 flex-wrap">
                          <span class="inline-flex items-center gap-1 font-mono text-[0.65rem] px-2 py-0.5 rounded bg-emerald-100 text-emerald-700">
                            <svg
                              class="w-3 h-3"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="2"
                              viewBox="0 0 24 24"
                            >
                              <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                            </svg>
                            ingested
                          </span>
                          <span
                            :if={status.shared_role_ids != []}
                            class="inline-flex items-center gap-1 font-mono text-[0.65rem] px-2 py-0.5 rounded bg-[#03b6d4]/10 text-[#03b6d4] cursor-default"
                            title={"Shared with: #{@all_roles |> Enum.filter(&(&1.id in status.shared_role_ids)) |> Enum.map(& &1.name) |> Enum.join(", ")}"}
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
                            shared
                          </span>
                        </div>
                        <span class="font-mono text-[0.6rem] text-black/30">
                          {format_datetime(status.ingested_at)}
                        </span>
                      </div>
                    <% true -> %>
                      <span class="font-mono text-[0.65rem] text-black/20">—</span>
                  <% end %>
                <% else %>
                  <span class="font-mono text-[0.65rem] text-black/20">—</span>
                <% end %>
              </td>
              <td class="font-mono text-[0.78rem] text-black/40 px-4 py-3 text-right">
                {format_datetime(entry.modified_at)}
              </td>
            </tr>
            <tr
              :if={Map.get(entry, :related_md)}
              class="border-b border-black/[0.04] last:border-0 bg-[#03b6d4]/[0.018]"
            >
              <td></td>
              <td class="px-4 py-1.5" colspan="4">
                <div class="flex items-center gap-2 pl-6 ml-4 border-l border-dashed border-black/10">
                  <svg
                    class="w-3 h-3 shrink-0 text-black/20"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M7 16V4m0 0L3 8m4-4l4 4" />
                  </svg>
                  <.file_icon
                    name={Map.get(entry, :related_md, %{name: ""}).name}
                    class="w-3.5 h-3.5 text-[#03b6d4]"
                  />
                  <span class="font-mono text-[0.78rem] text-black/40">
                    {Map.get(entry, :related_md, %{name: ""}).name}
                  </span>
                  <span class="font-mono text-[0.65rem] text-black/25">
                    {format_size(Map.get(entry, :related_md, %{}).size)}
                  </span>
                  <a
                    href={"/bo/preview/#{Path.join(@current_dir, Map.get(entry, :related_md, %{name: ""}).name)}"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="ml-auto font-mono text-[0.65rem] text-[#03b6d4]/50 hover:text-[#03b6d4] transition-colors flex items-center gap-1 pr-2"
                    title="Preview converted markdown"
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
                    preview md
                  </a>
                </div>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  # ── File Grid View ────────────────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :all_roles, :list, default: []

  def file_grid_view(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm max-h-[45vh] overflow-y-scroll p-4">
      <div class="flex items-center gap-2 mb-4 pb-3 border-b border-black/[0.06]">
        <input
          type="checkbox"
          phx-click="select_all"
          checked={MapSet.size(@selected) > 0 and MapSet.size(@selected) == length(@entries)}
          class="rounded border-black/20 text-[#03b6d4] focus:ring-[#03b6d4]"
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
              do: "border-[#03b6d4] bg-[#03b6d4]/[0.03] shadow-sm shadow-[#03b6d4]/10",
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
              class="rounded border-black/20 text-[#03b6d4] focus:ring-[#03b6d4]"
            />
          </div>
          <div class="absolute top-2 right-2 z-10 opacity-0 group-hover:opacity-100 transition-opacity flex items-center gap-0.5">
            <a
              :if={entry.type == :file}
              href={"/bo/preview/#{Path.join(@current_dir, entry.name)}"}
              target="_blank"
              rel="noopener noreferrer"
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-[#03b6d4] transition-colors"
              title="Preview in new tab"
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
            </a>
            <button
              phx-click="move_item"
              phx-value-path={Path.join(@current_dir, entry.name)}
              phx-value-type={entry.type}
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors"
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
              class="p-1 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors"
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
              :if={entry.type == :file}
              phx-click="share_item"
              phx-value-path={Path.join(@current_dir, entry.name)}
              class="p-1 hover:bg-[#03b6d4]/10 rounded-lg text-black/30 hover:text-[#03b6d4] transition-colors"
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
              class="p-1 hover:bg-red-500/10 rounded-lg text-black/30 hover:text-red-500 transition-colors"
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
            <button
              phx-click="navigate"
              phx-value-path={Path.join(@current_dir, entry.name)}
              class="w-full pt-8 pb-3 flex flex-col items-center"
            >
              <svg class="w-10 h-10 text-amber-400 mb-2" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
              <span class="font-mono text-[0.75rem] text-[#03b6d4] text-center leading-tight px-2 truncate max-w-full">
                {entry.name}
              </span>
            </button>
          <% else %>
            <div class="w-full pt-8 pb-3 flex flex-col items-center">
              <.file_icon name={entry.name} class={"w-10 h-10 mb-2 #{file_icon_color(entry.name)}"} />
              <span
                class="font-mono text-[0.75rem] text-black text-center leading-tight px-2 truncate max-w-full"
                title={entry.name}
              >
                {entry.name}
              </span>
              <span class="font-mono text-[0.6rem] text-black/30 mt-0.5">
                {format_size(entry.size)}
              </span>
              <% status = Map.get(@ingestion_map, entry.name, %{ingested_at: nil, stale?: false}) %>
              <%= cond do %>
                <% status.stale? -> %>
                  <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-amber-100 text-amber-600 mt-1">
                    stale
                  </span>
                <% status.ingested_at != nil -> %>
                  <div class="flex flex-col items-center gap-0.5 mt-1">
                    <span class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">
                      ingested
                    </span>
                    <span
                      :if={status.shared_role_ids != []}
                      class="font-mono text-[0.55rem] px-1.5 py-0.5 rounded bg-[#03b6d4]/10 text-[#03b6d4] cursor-default"
                      title={"Shared with: #{@all_roles |> Enum.filter(&(&1.id in status.shared_role_ids)) |> Enum.map(& &1.name) |> Enum.join(", ")}"}
                    >
                      shared
                    </span>
                  </div>
                <% true -> %>
              <% end %>
              <a
                :if={Map.get(entry, :related_md)}
                href={"/bo/preview/#{Path.join(@current_dir, Map.get(entry, :related_md, %{name: ""}).name)}"}
                target="_blank"
                rel="noopener noreferrer"
                class="mt-2 flex items-center gap-1 font-mono text-[0.6rem] text-[#03b6d4]/50 hover:text-[#03b6d4] transition-colors border-t border-dashed border-black/[0.06] pt-2 w-full justify-center"
                title="Preview converted markdown"
              >
                <.file_icon
                  name={Map.get(entry, :related_md, %{name: ""}).name}
                  class="w-3 h-3"
                /> md preview
              </a>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Upload Section ────────────────────────────────────────────────────────

  attr :uploads, :any, required: true

  def upload_section(assigns) do
    ~H"""
    <div>
      <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-3">Upload</p>
      <form id="upload-form" phx-submit="upload" phx-change="validate_upload">
        <div
          class="bg-white rounded-2xl border-2 border-dashed border-black/10 hover:border-[#03b6d4]/40 transition-colors p-6"
          phx-drop-target={@uploads.files.ref}
        >
          <div class="text-center">
            <svg
              class="w-8 h-8 mx-auto mb-2 text-black/20"
              fill="none"
              stroke="currentColor"
              stroke-width="1.5"
              viewBox="0 0 24 24"
            >
              <path d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
            </svg>
            <p class="font-mono text-[0.8rem] text-black/40 mb-1">
              Drop files here or
              <label class="text-[#03b6d4] hover:underline cursor-pointer">
                browse <.live_file_input upload={@uploads.files} class="hidden" />
              </label>
            </p>
            <p class="font-mono text-[0.65rem] text-black/25">
              .md .txt .pdf .docx .xlsx .csv — max 20 MB
            </p>
          </div>
        </div>

        <%= for entry <- @uploads.files.entries do %>
          <div class="flex items-center justify-between mt-3 px-2">
            <span class="font-mono text-[0.8rem] text-black truncate max-w-[60%]">
              {entry.client_name}
            </span>
            <div class="flex items-center gap-3">
              <div class="w-32 h-1.5 bg-black/5 rounded-full overflow-hidden">
                <div
                  class="h-full bg-[#03b6d4] rounded-full transition-all"
                  style={"width: #{entry.progress}%;"}
                />
              </div>
              <span class="font-mono text-[0.7rem] text-black/40">{entry.progress}%</span>
            </div>
          </div>
        <% end %>

        <button
          :if={@uploads.files.entries != []}
          type="submit"
          class="mt-4 font-mono text-[0.78rem] font-bold px-5 py-2 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
        >
          Upload {length(@uploads.files.entries)} file(s)
        </button>
      </form>
    </div>
    """
  end

  # ── Jobs Panel ────────────────────────────────────────────────────────────

  attr :jobs, :list, required: true
  attr :status_filter, :string, required: true

  def jobs_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">Jobs</p>
        <p class="font-mono text-[0.68rem] text-black/30">{length(@jobs)}</p>
      </div>

      <div class="flex gap-1 mb-3">
        <button
          :for={status <- ~w(all pending processing completed failed)}
          phx-click="filter_status"
          phx-value-status={status}
          class={[
            "font-mono text-[0.68rem] px-2 py-1 rounded-lg transition-colors",
            if(@status_filter == status,
              do: "bg-[#03b6d4] text-white",
              else: "bg-black/5 text-black/40 hover:bg-black/10"
            )
          ]}
        >
          {status}
        </button>
      </div>

      <div class="space-y-2 max-h-[80vh] overflow-y-auto">
        <div
          :if={@jobs == []}
          class="bg-white rounded-xl border border-dashed border-black/10 p-6 text-center"
        >
          <p class="font-mono text-[0.8rem] text-black/30">No jobs yet</p>
        </div>

        <div
          :for={job <- @jobs}
          class="bg-white rounded-xl border border-black/[0.06] shadow-sm p-4 space-y-2"
        >
          <div class="flex items-start justify-between gap-2">
            <p class="font-mono text-[0.82rem] text-black font-medium truncate" title={job.file_path}>
              {Path.basename(job.file_path)}
            </p>
            <span class={[
              "shrink-0 font-mono text-[0.65rem] px-2 py-0.5 rounded",
              status_color(job.status)
            ]}>
              {job.status}
            </span>
          </div>

          <div class="font-mono text-[0.68rem] text-black/40 space-y-0.5">
            <p>Mode: {job.mode}</p>
            <p>Started: {format_datetime(job.started_at)}</p>
            <p :if={job.completed_at}>Completed: {format_datetime(job.completed_at)}</p>
            <p :if={job.chunks_count > 0}>Chunks: {job.chunks_count}</p>
            <details :if={job.error} class="mt-1">
              <summary class="font-mono text-[0.7rem] text-red-500 cursor-pointer hover:text-red-600">
                Error details
              </summary>
              <pre class="mt-1 text-[0.65rem] text-red-400 whitespace-pre-wrap break-all">{job.error}</pre>
            </details>
          </div>

          <div class="flex gap-1.5 pt-1">
            <button
              :if={job.status in ~w(failed)}
              phx-click="retry_job"
              phx-value-id={job.id}
              class="font-mono text-[0.65rem] px-2 py-1 rounded-lg bg-black/5 text-black/50 hover:bg-black/10 transition-colors"
            >
              Retry
            </button>
            <button
              :if={job.status in ~w(pending processing)}
              phx-click="cancel_job"
              phx-value-id={job.id}
              class="font-mono text-[0.65rem] px-2 py-1 rounded-lg bg-red-500/10 text-red-500 hover:bg-red-500/20 transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Modal: Add Raw MD ─────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :current_dir, :string, required: true

  def modal_add_raw(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="fixed inset-0 bg-black/20 backdrop-blur-sm" phx-click="close_modal" />
      <div
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="relative bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-2xl overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-[#03b6d4]/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-[#03b6d4]"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Add Raw MD Content</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Paste or type Markdown — saved as a <span class="text-black/60 font-medium">.md</span>
                file in the current directory
              </p>
            </div>
          </div>
        </div>

        <form phx-submit="add_raw_content">
          <div class="px-6 pb-6 space-y-4">
            <div :if={@modal_error} class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>

            <div>
              <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
                Filename
              </label>
              <div class="flex items-center gap-2">
                <input
                  id="raw-filename-input"
                  type="text"
                  name="filename"
                  value={@modal_name}
                  phx-hook="FocusAndSelect"
                  placeholder="my-document"
                  class="flex-1 font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[#03b6d4] focus:ring-2 focus:ring-[#03b6d4]/20 outline-none transition-all placeholder:text-black/20"
                />
                <span class="font-mono text-[0.8rem] text-black/30 shrink-0">.md</span>
              </div>
            </div>

            <div>
              <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
                Content
              </label>
              <textarea
                name="content"
                rows="14"
                placeholder="# My Document&#10;&#10;Start writing your Markdown here..."
                class="w-full font-mono text-[0.82rem] px-4 py-3 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[#03b6d4] focus:ring-2 focus:ring-[#03b6d4]/20 outline-none transition-all placeholder:text-black/20 resize-none"
              ></textarea>
            </div>
          </div>

          <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-between">
            <p class="font-mono text-[0.68rem] text-black/30">
              Saving to:
              <span class="text-black/50">
                {if @current_dir == ".", do: "root", else: @current_dir}/
              </span>
            </p>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="close_modal"
                class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
              >
                Save File
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── Modal: Rename ─────────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_rename(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-[#03b6d4]/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-[#03b6d4]"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Rename</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Renaming <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>

        <form phx-submit="confirm_rename">
          <div class="px-6 pb-6">
            <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>
            <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
              New Name
            </label>
            <input
              type="text"
              name="name"
              value={@modal_name}
              class="w-full font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[#03b6d4] focus:ring-2 focus:ring-[#03b6d4]/20 outline-none transition-all"
            />
          </div>
          <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
            <button
              type="button"
              phx-click="close_modal"
              class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Rename
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── Modal: Delete Single ──────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_delete(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-red-500/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-red-500"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Delete</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Permanently delete <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>
        <div :if={@modal_error} class="px-6 pt-2 pb-0">
          <div class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
            <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
          </div>
        </div>
        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_delete"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-red-500 text-white hover:bg-red-600 shadow-sm shadow-red-500/20 transition-all"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Modal: Delete Selected ────────────────────────────────────────────────

  attr :selected, :any, required: true

  def modal_delete_selected(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-red-500/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-red-500"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Delete Selected</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Permanently delete
                <span class="text-black/60 font-medium">{MapSet.size(@selected)} item(s)</span>
              </p>
            </div>
          </div>
        </div>
        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_delete_selected"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-red-500 text-white hover:bg-red-600 shadow-sm shadow-red-500/20 transition-all"
          >
            Delete All ({MapSet.size(@selected)})
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Modal: New Folder ─────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_new_folder(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-amber-500/10 flex items-center justify-center shrink-0">
              <svg class="w-4.5 h-4.5 text-amber-500" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">New Folder</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Create a new folder in the current directory
              </p>
            </div>
          </div>
        </div>

        <form phx-submit="create_folder">
          <div class="px-6 pb-6">
            <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>
            <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
              Folder Name
            </label>
            <input
              id="new-folder-input"
              type="text"
              name="name"
              value={@modal_name}
              phx-hook="FocusAndSelect"
              placeholder="my-folder"
              class="w-full font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[#03b6d4] focus:ring-2 focus:ring-[#03b6d4]/20 outline-none transition-all placeholder:text-black/20"
            />
          </div>
          <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
            <button
              type="button"
              phx-click="close_modal"
              class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
            >
              Create
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── Modal: Move ───────────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :move_current_dir, :string, required: true
  attr :move_breadcrumbs, :list, required: true
  attr :move_folders, :list, required: true

  def modal_move(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-lg overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-indigo-500/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-indigo-500"
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
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Move</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Choose a destination for <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>

        <div class="px-6 pb-4">
          <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
            <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
          </div>

          <div class="flex items-center gap-1.5 mb-3 font-mono text-[0.72rem]">
            <button
              :if={@move_current_dir != "."}
              phx-click="move_go_back"
              class="flex items-center justify-center w-5 h-5 rounded-md bg-black/5 text-black/40 hover:bg-black/10 hover:text-black/60 transition-colors shrink-0 mr-0.5"
              title="Go back"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
              </svg>
            </button>
            <button
              phx-click="move_navigate"
              phx-value-path="."
              class="text-[#03b6d4] hover:underline"
            >
              root
            </button>
            <span :for={crumb <- @move_breadcrumbs} class="flex items-center gap-1">
              <span class="text-black/20">/</span>
              <button
                phx-click="move_navigate"
                phx-value-path={crumb.path}
                class="text-[#03b6d4] hover:underline"
              >
                {crumb.name}
              </button>
            </span>
          </div>

          <div class="mb-3 px-3 py-2 rounded-xl bg-indigo-50 border border-indigo-100">
            <p class="font-mono text-[0.7rem] text-indigo-600">
              Move to:
              <span class="font-semibold">
                {if @move_current_dir == ".", do: "root", else: @move_current_dir}
              </span>
            </p>
          </div>

          <div class="rounded-xl bg-[#fafafa] border border-black/[0.06] max-h-56 overflow-y-auto">
            <div :if={@move_folders == []} class="px-4 py-6 text-center">
              <p class="font-mono text-[0.75rem] text-black/30">No subfolders</p>
            </div>
            <div
              :for={folder <- @move_folders}
              phx-click="move_navigate"
              phx-value-path={Path.join(@move_current_dir, folder.name)}
              class="flex items-center gap-2.5 px-4 py-2.5 cursor-pointer transition-colors border-b border-black/[0.04] last:border-0 hover:bg-black/[0.02]"
            >
              <svg class="w-4 h-4 text-amber-400 shrink-0" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
              <span class="font-mono text-[0.8rem] text-black truncate">{folder.name}</span>
              <svg
                class="w-3.5 h-3.5 text-black/20 ml-auto shrink-0"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
              </svg>
            </div>
          </div>
        </div>

        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_move"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-indigo-500 text-white hover:bg-indigo-600 shadow-sm shadow-indigo-500/20 transition-all"
          >
            Move Here
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Share Modal ───────────────────────────────────────────────────────────

  attr :modal_name, :string, required: true
  attr :modal_error, :string, default: nil
  attr :all_roles, :list, required: true
  attr :share_modal_role_ids, :list, required: true

  def modal_share(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm">
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.06] w-full max-w-md mx-4 overflow-hidden">
        <div class="px-6 py-5 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
          <div>
            <h3 class="font-mono text-[0.9rem] font-bold text-black">Share with Roles</h3>
            <p class="font-mono text-[0.72rem] text-black/40 mt-0.5 truncate max-w-xs">
              {@modal_name}
            </p>
          </div>
          <button
            phx-click="close_modal"
            class="p-1.5 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div class="px-6 py-5">
          <p class="font-mono text-[0.72rem] text-black/40 mb-4">
            {if @share_modal_role_ids == [],
              do: "Private — only the ingesting role can access this file.",
              else: "Shared with #{length(@share_modal_role_ids)} role(s)."}
          </p>

          <p :if={@all_roles == []} class="font-mono text-[0.78rem] text-black/30 italic">
            No roles defined yet.
          </p>

          <div class="flex flex-wrap gap-2">
            <label
              :for={role <- @all_roles}
              class={[
                "flex items-center gap-2 px-3 py-2 rounded-xl border cursor-pointer transition-all select-none",
                if(role.id in @share_modal_role_ids,
                  do: "border-[#03b6d4] bg-[#03b6d4]/5 text-[#03b6d4]",
                  else: "border-black/10 bg-[#fafafa] text-black/50 hover:border-black/20"
                )
              ]}
            >
              <input
                type="checkbox"
                checked={role.id in @share_modal_role_ids}
                phx-click="toggle_share_role"
                phx-value-role_id={role.id}
                class="hidden"
              />
              <span class={[
                "w-2 h-2 rounded-full shrink-0",
                if(role.id in @share_modal_role_ids, do: "bg-[#03b6d4]", else: "bg-black/20")
              ]}>
              </span>
              <span class="font-mono text-[0.82rem] font-medium">{role.name}</span>
            </label>
          </div>

          <p :if={@modal_error} class="font-mono text-[0.72rem] text-red-500 mt-3">
            {@modal_error}
          </p>
        </div>

        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_share"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
          >
            {if @share_modal_role_ids == [], do: "Make Private", else: "Share"}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
