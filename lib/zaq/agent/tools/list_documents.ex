defmodule Zaq.Agent.Tools.ListDocuments do
  @moduledoc """
  ReAct tool: lists documents for a path from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  use Jido.Action,
    name: "list_documents",
    description: """
    List documents from a specific datasource provider path.
    Returns metadata records only.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      path: [type: :string, required: true, doc: "Provider path to list"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  def run(%{provider: provider, path: path} = params, context) do
    request =
      params
      |> Map.take([:config_id])
      |> Enum.into(%{"path" => path}, fn {k, v} -> {Atom.to_string(k), v} end)
      |> then(&%{provider: provider, params: &1})

    DataSourceTool.dispatch(
      :data_source_list_files,
      request,
      context,
      "Data source document listing failed",
      &on_ok/1
    )
  end

  defp on_ok(%{records: records} = payload) when is_list(records) do
    {:ok, Map.put_new(payload, :count, length(records))}
  end

  defp on_ok(payload), do: {:ok, payload}
end
