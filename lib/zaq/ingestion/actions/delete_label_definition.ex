defmodule Zaq.Ingestion.Actions.DeleteLabelDefinition do
  @moduledoc "Validated label deletion with definition revision and confirmed resource usage."
  use Jido.Action,
    name: "delete_label_definition",
    description:
      "Delete an authorized label definition and its assignments after usage confirmation",
    schema:
      Zoi.object(%{
        id: Zoi.integer(),
        expected_version: Zoi.integer(),
        expected_usage: Zoi.object(%{documents: Zoi.integer(), chunks: Zoi.integer()})
      }),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels

  @impl Jido.Action
  def run(params, context),
    do: {:ok, %{result: Labels.delete_definition(params, context[:actor])}}
end
