defmodule Zaq.Engine.Workflows.PendingApproval do
  @moduledoc """
  Internal success metadata requesting durable workflow suspension.

  This is not an exception or business output. Only the trusted HITL execution
  and replay paths may produce it in `workflow_control` metadata. Consumers must
  validate it against the current run/step and a persisted pending approval
  before suspending. Approval lookup and lifecycle remain owned by Workflows.
  """

  alias Jido.Action.Error
  alias Zaq.Engine.Workflows.StepApproval

  @enforce_keys [:run_id, :step_name, :approval_token]
  defstruct [:run_id, :step_name, :approval_token]

  @type t :: %__MODULE__{run_id: binary(), step_name: String.t(), approval_token: binary()}

  @doc "Checks the exact durable association; this does not authorize an approval decision."
  @spec validate(t(), binary(), String.t(), StepApproval.t() | nil) ::
          :ok | {:error, Exception.t()}
  def validate(
        %__MODULE__{run_id: run_id, step_name: step_name, approval_token: token},
        run_id,
        step_name,
        %StepApproval{
          workflow_run_id: run_id,
          step_name: step_name,
          approval_token: token,
          status: "pending"
        }
      )
      when is_binary(run_id) and byte_size(run_id) > 0 and
             is_binary(step_name) and byte_size(step_name) > 0 and
             is_binary(token) and byte_size(token) > 0,
      do: :ok

  def validate(_control, _run_id, _step_name, _approval),
    do: {:error, Error.validation_error("Invalid pending approval association")}
end
