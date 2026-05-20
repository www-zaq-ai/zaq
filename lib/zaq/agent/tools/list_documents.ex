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

  alias Zaq.Event
  alias Zaq.NodeRouter

  def run(%{provider: provider, path: path} = params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    request =
      params
      |> Map.take([:config_id])
      |> Enum.into(%{"path" => path}, fn {k, v} -> {Atom.to_string(k), v} end)
      |> then(&%{provider: provider, params: &1})

    event = Event.new(request, :channels, opts: [action: :data_source_list_files])

    case node_router.dispatch(event).response do
      {:ok, %{records: records} = payload} when is_list(records) ->
        {:ok, Map.put_new(payload, :count, length(records))}

      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, "Data source document listing failed: #{inspect(reason)}"}

      other ->
        {:error, "Unexpected data source response: #{inspect(other)}"}
    end
  end
end
