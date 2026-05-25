defmodule ZaqWeb.Live.BO.AI.WorkflowResultHelpers do
  @moduledoc false

  def clean_results(nil), do: %{}

  def clean_results(results) when is_map(results) do
    results
    |> Map.drop(["__cascade__", :__cascade__])
    |> Enum.reject(fn {_k, v} -> is_map(v) and Map.has_key?(v, "__cascade__") end)
    |> Map.new()
  end
end
