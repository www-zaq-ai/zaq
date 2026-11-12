defmodule Zaq.Ingestion.Actions.EditResourceLabels do
  @moduledoc "Validated BO label mutation; delegates authorization and persistence to Labels."
  use Jido.Action,
    name: "edit_resource_labels",
    description: "Apply an authorized manual labeling operation",
    schema: Zoi.object(%{resource: Zoi.map(), edits: Zoi.list(Zoi.map())}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels

  @impl Jido.Action
  def run(params, context) do
    {:ok,
     %{
       result:
         Labels.edit_resource(
           params.resource,
           params.edits,
           context[:actor],
           context[:opts] || []
         )
     }}
  end
end
