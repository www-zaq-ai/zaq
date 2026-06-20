defmodule ZaqWeb.Components.DesignSystem.IngestionFileStatus do
  @moduledoc """
  Shared ingestion status defaults for ingestion file browser views (grid and list).
  """

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
  def record_path(%{name: name}), do: name

  def record_file?(entry), do: record_kind(entry) == :file
  def record_folder?(entry), do: record_kind(entry) == :folder

  def record_local_type(entry) do
    if record_folder?(entry), do: :directory, else: :file
  end

  defp record_kind(%{kind: :folder}), do: :folder
  defp record_kind(%{kind: "folder"}), do: :folder
  defp record_kind(%{type: :directory}), do: :folder
  defp record_kind(_), do: :file
end
