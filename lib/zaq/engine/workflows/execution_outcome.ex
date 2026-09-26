defmodule Zaq.Engine.Workflows.ExecutionOutcome do
  @moduledoc """
  Interprets Jido execution results for workflow consumers.

  Jido owns input/output validation and execution. This module only separates
  business results, metadata, structured branch failures and candidate control.
  A `:pending` classification is not permission to suspend: the consumer must
  verify the producer and `PendingApproval.validate/4` against durable state.
  Errors always remain failures, even when Jido retains success metadata after
  rejecting an action's output. Domain data is never searched for control.
  """

  alias Jido.Action.Error
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.PendingApproval

  @type outcome ::
          {:ok, term(), map()}
          | {:error, term(), map()}
          | {:skipped, Exception.t(), map()}
          | {:pending, PendingApproval.t(), map()}

  @doc "Classifies a Jido result without executing actions or accessing persistence."
  @spec classify(tuple()) :: outcome()
  def classify({status, result}) when status in [:ok, :error],
    do: classify({status, result, %{}})

  def classify({status, result, metadata}) when status in [:ok, :error] do
    case metadata_map(metadata) do
      {:ok, metadata} ->
        ordinary = Map.drop(metadata, [:workflow_control, "workflow_control"])
        classify_result(status, result, Map.get(metadata, :workflow_control), ordinary)

      {:error, error} ->
        {:error, error, %{}}
    end
  end

  def classify(_result),
    do: {:error, Error.validation_error("Invalid workflow execution result"), %{}}

  @doc "Preserves Jido's structured type, message, details and retryability for recording."
  @spec error_details(term()) :: map()
  def error_details(reason), do: Error.to_map(reason)

  defp classify_result(:ok, result, %PendingApproval{} = control, metadata)
       when is_map(result) and map_size(result) == 0,
       do: {:pending, control, metadata}

  defp classify_result(:ok, _result, %PendingApproval{}, metadata),
    do:
      {:error, Error.validation_error("Pending approval requires empty business output"),
       metadata}

  defp classify_result(:ok, result, _control, metadata), do: {:ok, result, metadata}

  defp classify_result(:error, %ConditionNotMet{} = exception, _control, metadata),
    do: {:skipped, exception, metadata}

  defp classify_result(
         :error,
         %{details: %{original_exception: %ConditionNotMet{} = exception}},
         _control,
         metadata
       ),
       do: {:skipped, exception, metadata}

  defp classify_result(:error, error, _control, metadata), do: {:error, error, metadata}

  defp metadata_map(metadata) when is_map(metadata), do: {:ok, metadata}

  defp metadata_map(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata), do: {:ok, Map.new(metadata)}, else: invalid_metadata()
  end

  defp metadata_map(_metadata), do: invalid_metadata()

  defp invalid_metadata,
    do: {:error, Error.validation_error("Workflow metadata must be a map or keyword list")}
end
