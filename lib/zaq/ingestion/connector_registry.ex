defmodule Zaq.Ingestion.ConnectorRegistry do
  @moduledoc """
  Config-driven registry of active ingestion connectors.

  Derives the connector list from application config at call time — no runtime
  registration, no ETS table. Active connectors are known from config at startup.

  ## Adding a future connector

  When a new connector ships (e.g. SharePoint, Google Drive), add a clause to
  `list_connectors/0` that checks whether its channel is configured and enabled
  in application config, then appends an entry with the connector's prefix id,
  display label, and icon key.
  """

  alias Zaq.Ingestion.FileExplorer

  @doc """
  Returns the list of active connectors derived from application config.
  Each entry has `:id` (source prefix segment), `:label` (display name),
  and `:icon` (atom used to select the correct SVG in the UI).
  """
  @spec list_connectors() :: [%{id: String.t(), label: String.t(), icon: atom()}]
  def list_connectors do
    filesystem_connectors()
  end

  defp filesystem_connectors do
    FileExplorer.list_volumes()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name -> %{id: name, label: name, icon: :folder} end)
  end
end
