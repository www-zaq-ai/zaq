defmodule Zaq.Ingestion.Actions.SaveLabelDefinition do
  @moduledoc "Validated BO label mutation; delegates authorization and persistence to Labels."
  use Jido.Action,
    name: "save_label_definition",
    description: "Apply an authorized manual labeling operation",
    schema: Zoi.object(%{attrs: Zoi.map()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels

  @impl Jido.Action
  def run(params, context) do
    {:ok, %{result: Labels.save_definition(params.attrs, context[:actor])}}
  end
end
