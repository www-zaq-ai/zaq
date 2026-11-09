defmodule Zaq.TestSupport.NestedActionProbe do
  @moduledoc "A real composed Action for nested invocation integration fixtures."

  use Jido.Action,
    name: "nested_action_probe",
    description: "Executes a bounded chain of nested probe Actions",
    schema: [depth: [type: :non_neg_integer, default: 0]]

  alias Zaq.Agent.Tools.ActionContract

  @impl true
  def run(%{depth: depth}, context) do
    if owner = context[:test_pid] do
      send(
        owner,
        {:nested_probe, self(),
         Map.take(context, [:tool_call_id, :tool_invocation_path, :request_id, :run_id]),
         is_function(context[:on_tool_event], 1)}
      )
    end

    if depth > 0 do
      ActionContract.execute(__MODULE__, %{depth: depth - 1}, context,
        timeout: 2_000,
        max_retries: 0
      )
    else
      {:ok, %{value: 42}}
    end
  end
end
