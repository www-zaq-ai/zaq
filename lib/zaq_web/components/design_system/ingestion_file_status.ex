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
end
