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

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider, query: query} = params, context) do
    request =
      %{"query" => query}
      |> DataSourceTool.put_many_if_present([
        {"path", Map.get(params, :path)},
        {"config_id", Map.get(params, :config_id)}
      ])
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_search_files,
      request,
      context,
      "Data source document search failed",
      &on_ok/1
    )
  end

  defp on_ok(%{records: records} = payload) when is_list(records) do
    {:ok, Map.put_new(payload, :count, length(records))}
  end

  defp on_ok(payload), do: {:ok, payload}
end
