defmodule Zaq.Engine.Workflows.Conditions.ConditionNotMet do
  @moduledoc false

  defexception [:condition_name, :field, :op, :actual, :expected]

  def message(%{condition_name: name, field: field, op: op, actual: actual}) do
    "condition_not_met:#{name} (#{field} #{op} #{inspect(actual)})"
  end
end
