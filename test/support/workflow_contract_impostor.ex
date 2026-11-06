defmodule Zaq.Engine.Workflows.Test.ContractImpostor do
  @moduledoc false
  def schema, do: [input: [type: :any]]
  def output_schema, do: [value: [type: :any]]
  def on_success(result, _context), do: {:ok, result}
  def on_failure(_error, _context), do: :ok
end
