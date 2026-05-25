defmodule Zaq.Agent.Tools.ItemOutcome do
  @moduledoc false

  def handle({:error, reason}, :fail_workflow, _idx, _t0, _results, _errors, _logs, _deps) do
    {:halt, {:error, reason}}
  end

  def handle({:ok, value}, _strategy, idx, t0, results, errors, logs, deps) do
    log = deps.log_entry.(:item_ok, t0, %{index: idx})
    {:cont, {[value | results], errors, [log | logs]}}
  end

  def handle({:error, reason}, _strategy, idx, t0, results, errors, logs, deps) do
    log = deps.log_entry.(:item_error, t0, %{index: idx, reason: deps.format_reason.(reason)})
    {:cont, {results, [%{index: idx, reason: reason} | errors], [log | logs]}}
  end
end
