defmodule Zaq.Agent.Tools.DataSource.DeleteDocument do
  @moduledoc """
  ReAct tool: deletes a loaded datasource record.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @schema Zoi.object(%{
            record:
              Zaq.Contracts.Record.zoi_type(description: "Loaded datasource record to delete.")
          })

  @output_schema Zoi.object(%{
                   status:
                     Zoi.string(description: "Operation status.")
                     |> Zoi.optional(),
                   result:
                     Zoi.map(description: "Provider-specific deletion result.")
                     |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "delete_document",
    output_schema: @output_schema,
    description: """
    Delete a loaded datasource record.
    This removes the provider document only; indexed ZAQ document cleanup is handled by ingestion deltas.
    """,
    schema: @schema

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.Record

  @impl Jido.Action
  def run(%{record: %Record{} = record}, context) do
    DataSourceTool.dispatch(
      :data_source_delete_file,
      %{record: record},
      context,
      "Data source document deletion failed"
    )
  end

  def run(%{record: _other}, _context), do: {:error, {:invalid_input, :expected_record}}
  def run(_params, _context), do: {:error, {:invalid_input, :expected_record}}
end
