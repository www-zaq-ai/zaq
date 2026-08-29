defmodule ZaqWeb.Components.DesignSystem.IngestionFileStatus do
  @moduledoc """
  Shared ingestion status defaults for ingestion file browser views (grid and list).
  """

  use Phoenix.Component

  @doc false
  def file_ingestion_status(ingestion_map, name) do
    Map.merge(
      %{
        ingested_at: nil,
        stale?: false,
        job_status: nil,
        permissions_count: 0,
        is_public: false,
        can_share?: false,
        watch_status: "unwatched",
        watch_error: nil,
        watchable?: false
      },
      Map.get(ingestion_map, name, %{})
    )
  end

  # Ingestion browser rows receive canonical Records for every data source and
  # constrain actions via assigns instead of parallel provider-specific trees.
  def record_path(%{path: path}) when is_binary(path), do: path
  def record_path(%{id: id}) when is_binary(id), do: id
  def record_path(%{name: name}), do: name

  def record_file?(entry), do: record_kind(entry) == :file
  def record_folder?(entry), do: record_kind(entry) == :folder

  def record_icon_url(%{icon: icon}) when is_binary(icon) and icon != "", do: icon

  def record_icon_url(%{raw: raw}) when is_map(raw) do
    Map.get(raw, "iconLink") || Map.get(raw, :iconLink) || Map.get(raw, "icon_link") ||
      Map.get(raw, :icon_link)
  end

  def record_icon_url(_entry), do: nil

  attr :share_editable, :boolean, default: false
  attr :permissions_count, :integer, required: true
  attr :path, :string, required: true
  attr :icon, :boolean, default: false

  def shared_badge(assigns) do
    ~H"""
    <button
      :if={@permissions_count > 0}
      type="button"
      phx-click={if @share_editable, do: "share_item", else: "view_provider_permissions"}
      phx-value-path={@path}
      class="zaq-pill zaq-pill--shared zaq-text-caption"
      title={
        if @share_editable,
          do: "Shared with #{@permissions_count} person(s)/team(s)",
          else:
            "Permissions are managed in the data source. Refresh ingestion after changing them there."
      }
    >
      <svg
        :if={@icon}
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
    </button>
    """
  end

  attr :path, :string, required: true
  attr :status, :string, default: "unwatched"
  attr :watch_error, :string, default: nil
  attr :watchable, :boolean, default: false
  attr :watch_inherited, :boolean, default: false
  attr :watch_supported, :boolean, default: true
  attr :watch_disabled_reason, :string, default: nil

  def watch_status_dot(assigns) do
    assigns =
      assigns
      |> assign(:enabled, assigns.watchable and assigns.watch_supported)
      |> assign(
        :label,
        watch_status_label(
          assigns.status,
          assigns.watchable,
          assigns.watch_inherited,
          assigns.watch_supported,
          assigns.watch_disabled_reason
        )
      )

    ~H"""
    <button
      type="button"
      phx-click="toggle_watch_status"
      phx-value-path={@path}
      phx-value-watch_error={@watch_error}
      disabled={not @enabled}
      class={[
        "inline-flex h-7 w-7 items-center justify-center rounded-full zaq-focus-visible",
        @enabled && "cursor-pointer hover:bg-[var(--zaq-surface-color-elevated)]",
        not @enabled && "cursor-not-allowed opacity-60"
      ]}
      title={@label}
      aria-label={@label}
    >
      <span class={["h-2.5 w-2.5 rounded-full", watch_status_dot_class(@status, @enabled)]} />
    </button>
    """
  end

  defp watch_status_label(_status, _watchable, _inherited, false, reason) when is_binary(reason),
    do: reason

  defp watch_status_label(_status, _watchable, _inherited, false, _reason),
    do: "Watching is not supported"

  defp watch_status_label(_status, _watchable, true, _watch_supported, _reason),
    do: "Watched through parent folder"

  defp watch_status_label(_status, false, _inherited, _watch_supported, _reason),
    do: "Ingest before watching"

  defp watch_status_label("pending", _watchable, _inherited, _watch_supported, _reason),
    do: "Watch setup pending"

  defp watch_status_label("watched", _watchable, _inherited, _watch_supported, _reason),
    do: "Watched. Click to unwatch"

  defp watch_status_label("error", _watchable, _inherited, _watch_supported, _reason),
    do: "Watch setup failed. Click to retry"

  defp watch_status_label(_status, _watchable, _inherited, _watch_supported, _reason),
    do: "Not watched. Click to watch"

  defp watch_status_dot_class(_status, false), do: "bg-[var(--zaq-border-color-strong)]"
  defp watch_status_dot_class("pending", true), do: "bg-[var(--zaq-border-color-warning)]"
  defp watch_status_dot_class("watched", true), do: "bg-[var(--zaq-border-color-success)]"
  defp watch_status_dot_class("error", true), do: "bg-[var(--zaq-border-color-danger)]"
  defp watch_status_dot_class(_status, true), do: "bg-[var(--zaq-border-color-strong)]"

  defp record_kind(%{kind: :folder}), do: :folder
  defp record_kind(%{kind: "folder"}), do: :folder
  defp record_kind(%{type: :directory}), do: :folder
  defp record_kind(_), do: :file
end
