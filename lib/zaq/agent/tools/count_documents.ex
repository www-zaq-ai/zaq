defmodule Zaq.Agent.Tools.CountDocuments do
  @moduledoc """
  ReAct tool: counts and lists the documents the user has access to in the
  ZAQ knowledge base.

  Delegates to `Zaq.Ingestion.DocumentAccess` via NodeRouter, respecting
  the same permission model used by the search tool. Respects `:source_filter`
  from context so a file chip (e.g. @zaq) restricts results to that folder.

  Each document in the response includes a `:preview_url` the UI renders as a
  clickable link so the user can open the file directly.
  """

  use Jido.Action,
    name: "count_documents",
    description: """
    Count and list all files visible to this user, tagged as ingested
    (in the knowledge base) or not yet ingested. Use this when the user asks
    how many documents they have, what files are in the knowledge base, which
    files have been ingested, or wants a summary of available files.
    If a source filter (file chip) is active, only files from that folder or
    file are included.
    """,
    schema: []

  alias Zaq.Agent.Status
  alias Zaq.Ingestion.DocumentAccess
  alias Zaq.NodeRouter

  @preview_base "/bo/preview"

  def run(_params, context) do
    Status.broadcast(
      Map.get(context, :status_context),
      :retrieving,
      "ZAQ is counting your documents…",
      Map.get(context, :node_router, NodeRouter)
    )

    person_id = Map.get(context, :person_id)
    team_ids = Map.get(context, :team_ids, [])
    skip_permissions = Map.get(context, :skip_permissions, false)
    source_filter = Map.get(context, :source_filter)
    node_router_mod = Map.get(context, :node_router, NodeRouter)

    opts =
      [
        person_id: person_id,
        team_ids: team_ids,
        skip_permissions: skip_permissions,
        source_filter: source_filter
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    try do
      documents =
        node_router_mod.call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts])
        |> unwrap_router_result()
        |> Enum.map(&enrich_with_preview/1)

      ingested_count = Enum.count(documents, & &1.ingested)

      {:ok, %{total: length(documents), ingested_count: ingested_count, documents: documents}}
    rescue
      e -> {:error, "Document count failed: #{Exception.message(e)}"}
    end
  end

  defp enrich_with_preview(%{source: source} = doc) do
    Map.put(doc, :preview_url, "#{@preview_base}/#{source}")
  end

  defp unwrap_router_result({:ok, value}), do: value
  defp unwrap_router_result(value), do: value
end
