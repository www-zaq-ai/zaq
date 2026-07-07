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
        can_share?: false
      },
      Map.get(ingestion_map, name, %{})
    )
  end

  # Existing local-volume UI now receives canonical Records. Future external
  # data sources should pass the same shape and constrain actions via assigns
  # instead of adding a parallel browser component tree.
  def record_path(%{path: path}) when is_binary(path), do: path
  def record_path(%{id: id}) when is_binary(id), do: id
  def record_path(%{name: name}), do: name

  def record_file?(entry), do: record_kind(entry) == :file
  def record_folder?(entry), do: record_kind(entry) == :folder

  def record_local_type(entry) do
    if record_folder?(entry), do: :directory, else: :file
  end

  def record_icon_url(%{icon: icon}) when is_binary(icon) and icon != "", do: icon

  def record_icon_url(%{raw: raw}) when is_map(raw) do
    Map.get(raw, "iconLink") || Map.get(raw, :iconLink) || Map.get(raw, "icon_link") ||
      Map.get(raw, :icon_link)
  end

  def record_icon_url(_entry), do: nil

  def preview_path(entry, _current_volume, true), do: record_path(entry)

  def preview_path(entry, current_volume, false),
    do: Path.join([current_volume, record_path(entry)])

  def related_record(%{attributes: attrs}) when is_map(attrs) do
    Map.get(attrs, "related_record") || Map.get(attrs, :related_record)
  end

  def related_record(_entry), do: nil

  def related_record_name(record), do: Map.get(record, "name") || Map.get(record, :name) || ""
  def related_record_path(record), do: Map.get(record, "path") || Map.get(record, :path) || ""

  def related_record_preview_path(record),
    do: Map.get(record, "preview_path") || Map.get(record, :preview_path)

  def related_record_size(record), do: Map.get(record, "size") || Map.get(record, :size)

  def related_record_preview_path(record, current_volume) do
    case related_record_preview_path(record) do
      path when is_binary(path) and path != "" -> path
      _ -> Path.join([current_volume, related_record_path(record)])
    end
  end

  attr :provider_mode, :boolean, default: false
  attr :permissions_count, :integer, required: true
  attr :path, :string, required: true
  attr :icon, :boolean, default: false

  def shared_badge(assigns) do
    ~H"""
    <button
      :if={@permissions_count > 0}
      type="button"
      phx-click={if @provider_mode, do: "view_provider_permissions", else: "share_item"}
      phx-value-path={@path}
      class="zaq-pill zaq-pill--shared zaq-text-caption"
      title={
        if @provider_mode,
          do:
            "Permissions are managed in the data source. Refresh ingestion after changing them there.",
          else: "Shared with #{@permissions_count} person(s)/team(s)"
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

  defp record_kind(%{kind: :folder}), do: :folder
  defp record_kind(%{kind: "folder"}), do: :folder
  defp record_kind(%{type: :directory}), do: :folder
  defp record_kind(_), do: :file
end
