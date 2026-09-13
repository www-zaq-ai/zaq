defmodule Zaq.TestSupport.BudgetProbeTool do
  @moduledoc "Controlled tool for real Factory/Jido execution-budget regression tests."

  use Jido.Action,
    name: "budget_probe",
    description: "Return a value after the test releases this tool",
    schema: Zoi.object(%{value: Zoi.string()})

  def tool_timeout_ms, do: 45_000

  @impl true
  def run(%{value: value}, %{test_pid: test_pid}) do
    send(test_pid, {:budget_probe_started, self(), value})

    receive do
      :release -> {:ok, %{value: value}}
    after
      5_000 -> {:error, :probe_not_released}
    end
  end
end
