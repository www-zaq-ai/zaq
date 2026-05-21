defmodule Zaq.Engine.Workflows.Conditions.WaitingForApproval do
  @moduledoc false

  defexception [:step_name, :run_id, :approval_token]

  def message(%{step_name: step_name, run_id: run_id}) do
    "waiting_for_approval:#{step_name} (run_id=#{run_id})"
  end
end
