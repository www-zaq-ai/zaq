defmodule Zaq.Agent.Tools.DataSource.UpdateDocument do
  @moduledoc """
  ReAct tool: updates a document on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @schema Zoi.object(%{
            record:
              Zaq.Contracts.Record.zoi_type(description: "Loaded datasource record to update."),
            changes:
              Zoi.object(%{
                name:
                  Zoi.string(description: "Optional updated document name/title")
                  |> Zoi.optional(),
                content:
                  Zoi.string(description: "Optional updated textual content")
                  |> Zoi.optional(),
                path:
                  Zoi.string(
                    description:
                      "Optional destination parent path. Omit for content-only edits and renames."
                  )
                  |> Zoi.optional(),
                parent_id:
                  Zoi.string(description: "Optional updated provider parent identifier")
                  |> Zoi.optional(),
                mime_type:
                  Zoi.string(description: "Optional updated provider MIME type")
                  |> Zoi.optional()
              })
          })

  @output_schema Zoi.object(
                   %{
                     record:
                       Zaq.Contracts.Record.zoi_type(
                         description: "Updated document metadata record"
                       )
                       |> Zoi.optional()
                   },
                   unrecognized_keys: :preserve
                 )

  use Zaq.Engine.Workflows.Action,
    name: "update_document",
    output_schema: @output_schema,
    description: """
    Update a loaded datasource record.
    Returns provider metadata for the updated document.
    """,
    schema: @schema

  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.Record

  @impl Jido.Action
  def run(%{record: %Record{} = record, changes: changes}, context) when is_map(changes) do
    update_params = update_params(changes)

    DataSourceTool.dispatch(
      :data_source_update_file,
      %{record: record, params: update_params},
      context,
      "Data source document update failed"
    )
  end

  def run(%{record: %Record{}, changes: _other}, _context),
    do: {:error, {:invalid_input, :expected_changes}}

  def run(%{record: %Record{}}, _context), do: {:error, {:invalid_input, :expected_changes}}
  def run(%{record: _other}, _context), do: {:error, {:invalid_input, :expected_record}}
  def run(_params, _context), do: {:error, {:invalid_input, :expected_record}}

  defp update_params(changes) do
    Enum.reduce([:name, :content, :path, :parent_id, :mime_type], %{}, fn key, acc ->
      DataSourceTool.put_if_present(acc, Atom.to_string(key), value(changes, key))
    end)
  end

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
