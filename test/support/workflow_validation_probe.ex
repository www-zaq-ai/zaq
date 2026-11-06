defmodule Zaq.Engine.Workflows.Test.ValidationProbe do
  @moduledoc false
  use Jido.Action,
    name: "workflow_validation_probe",
    schema: [value: [type: :pos_integer, default: 1]],
    output_schema: [value: [type: :integer, required: true]]

  @impl true
  def on_before_validate_params(params) do
    notify(params.observer, :before_params)
    {:ok, params}
  end

  @impl true
  def on_after_validate_params(params) do
    notify(params.observer, {:after_params, params.value})
    {:ok, params}
  end

  @impl true
  def on_before_validate_output(output) do
    notify(output.observer, :before_output)
    {:ok, output}
  end

  @impl true
  def on_after_validate_output(output) do
    notify(output.observer, :after_output)
    {:ok, Map.delete(output, :observer)}
  end

  @impl true
  def run(params, context) do
    notify(
      params.observer,
      {:executed, context.action_metadata.name, context.actor, context.skip_permissions}
    )

    value = if context[:invalid_output], do: "wrong", else: params.value
    {:ok, %{value: value, observer: params.observer}}
  end

  defp notify(observer, message) do
    observer |> String.to_charlist() |> :erlang.list_to_pid() |> send(message)
  end
end
