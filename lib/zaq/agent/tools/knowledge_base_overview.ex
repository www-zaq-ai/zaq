defmodule Zaq.Agent.Tools.KnowledgeBaseOverview do
  @moduledoc """
  ReAct tool: counts and lists the documents the user has access to in the
  ZAQ knowledge base.

  Delegates to `Zaq.Ingestion.DocumentAccess` via NodeRouter, respecting
  the same permission model used by the search tool. Respects `:source_filter`
  from context so a file chip (e.g. @zaq) restricts results to that folder.

  Each document in the response includes a `:preview_url` the UI renders as a
  clickable link so the user can open the file directly.

  ## Expected context keys

  - `:person_id` — ID of the requesting person; `nil` returns only public docs.
  - `:team_ids` — list of team IDs the person belongs to (default `[]`).
  - `:skip_permissions` — when `true`, bypasses permission filtering (admin use).
  - `:source_filter` — list of source path prefixes to restrict results; `nil` means all.
  - `:status_context` — passed to `Status.broadcast/4` for streaming progress events.
  - `:node_router` — override the NodeRouter module (default `Zaq.NodeRouter`).
  """

  use Jido.Action,
    name: "knowledge_base_overview",
    description: """
    List and count all files the user can access, showing which are ingested
    into the knowledge base and which are not yet indexed.

    USE THIS TOOL when the user:
    - asks how many documents or files they have ("how many files do I have?")
    - asks how many files are in the system, knowledge base, or ZAQ ("how many files in the system?")
    - wants to see what is in their knowledge base ("what files are in ZAQ?")
    - asks which files have or have not been ingested/indexed
    - wants a directory-style overview of available files
    - asks what documents exist or are available

    ALWAYS call this tool fresh — never answer from memory or a prior result
    in this conversation. File counts and ingestion status change over time, so
    a cached answer is unreliable. Every question about counts or file lists
    requires a new tool call.

    DO NOT use this tool to answer questions about the content of documents —
    use the search tool for that. This tool returns file metadata (name, path,
    ingestion status, preview URL), not document content.

    If a source filter (file chip such as @folder) is active, only files under
    that path are returned.
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
      "ZAQ is listing your knowledge base files…",
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

    router_result =
      node_router_mod.call(:ingestion, DocumentAccess, :list_files_with_ingestion_status, [opts])

    case router_result do
      {:error, reason} ->
        {:error, "Document count failed: #{inspect(reason)}"}

      result ->
        documents =
          result
          |> unwrap_ok()
          |> Enum.map(&enrich_with_preview/1)

        ingested_count = Enum.count(documents, & &1.ingested)
        {:ok, %{total: length(documents), ingested_count: ingested_count, documents: documents}}
    end
  end

  defp enrich_with_preview(%{source: source} = doc) do
    Map.put(doc, :preview_url, "#{@preview_base}/#{source}")
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok(value), do: value
end
