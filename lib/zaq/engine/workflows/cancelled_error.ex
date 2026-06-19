defmodule Zaq.Engine.Workflows.CancelledError do
  @moduledoc "Raised by StepRunner when a run has been cancelled between steps."

  defexception [:run_id, message: "workflow run cancelled"]

  @impl true
  def exception(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    %__MODULE__{run_id: run_id, message: "workflow run #{run_id} cancelled"}
  end
end
