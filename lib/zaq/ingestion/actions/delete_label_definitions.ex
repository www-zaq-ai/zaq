defmodule Zaq.Ingestion.Actions.DeleteLabelDefinitions do
  @moduledoc "Validated atomic bulk deletion using the same confirmation contract as single deletion."
  use Jido.Action,
    name: "delete_label_definitions",
    description: "Delete confirmed label definitions and assignments atomically",
    schema:
      Zoi.object(%{
        labels:
          Zoi.list(
            Zoi.object(%{
              id: Zoi.integer(),
              expected_version: Zoi.integer(),
              expected_usage: Zoi.object(%{documents: Zoi.integer(), chunks: Zoi.integer()})
            })
          )
      }),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels

  @impl Jido.Action
  def run(params, context),
    do: {:ok, %{result: Labels.delete_definitions(params.labels, context[:actor])}}
end
