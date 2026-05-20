defmodule Zaq.Agent.Tools.SearchDocuments do
  @moduledoc """
  ReAct tool: searches documents for a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1` and returns metadata
  records only.
  """

  use Jido.Action,
    name: "search_documents",
    description: """
    Search documents from a specific datasource provider.
    Returns metadata results only. Use get_document to fetch a selected result.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      query: [type: :string, required: true, doc: "Search query"],
      path: [type: :string, required: false, doc: "Optional path filter"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Event
  alias Zaq.NodeRouter

  def run(%{provider: provider, query: query} = params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    request =
      %{"query" => query}
      |> maybe_put("path", Map.get(params, :path))
      |> maybe_put("config_id", Map.get(params, :config_id))
      |> then(&%{provider: provider, params: &1})

    event = Event.new(request, :channels, opts: [action: :data_source_search_files])

    case node_router.dispatch(event).response do
      {:ok, %{records: records} = payload} when is_list(records) ->
        {:ok, Map.put_new(payload, :count, length(records))}

      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, "Data source document search failed: #{inspect(reason)}"}

      other ->
        {:error, "Unexpected data source response: #{inspect(other)}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
