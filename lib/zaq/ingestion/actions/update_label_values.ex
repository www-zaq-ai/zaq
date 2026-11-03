defmodule Zaq.Ingestion.Actions.UpdateLabelValues do
  @moduledoc "Validated bulk value correction on explicit resource assignments; no agent tool exposure."
  use Jido.Action,
    name: "update_label_values",
    description: "Replace or clear a label value on selected authorized resources",
    schema:
      Zoi.object(%{label_id: Zoi.integer(), resources: Zoi.list(Zoi.map()), value: Zoi.string()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Ingestion.Labels.ValueManagement

  @impl Jido.Action
  def run(params, context) do
    {:ok,
     %{
       result:
         ValueManagement.update(params.label_id, params.resources, params.value, context[:actor])
     }}
  end
end
