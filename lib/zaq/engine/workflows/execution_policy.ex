defmodule Zaq.Engine.Workflows.ExecutionPolicy do
  @moduledoc """
  Explicit workflow execution policy; Jido enforces these values.

  Wrappers do not add attempts or deadlines. Real actions run inline when untimed;
  positive timeouts are per attempt, with Jido owning isolation and cleanup.
  Map retry allows three total attempts, subject to Jido's retryability rules.
  A wrapper must not silently inherit a workflow-wide deadline: zero timeout does
  not cancel Jido's inherited deadline, and no workflow-wide budget is defined.
  """

  alias Jido.Action.Error

  @doc "Options for the outer StepRunner action at both ordinary and map boundaries."
  @spec outer_options() :: keyword()
  def outer_options, do: [timeout: 0, max_retries: 0, backoff: 0, telemetry: :silent]

  @doc "Options for the actual action; invalid timeout configuration is non-retryable."
  @spec inner_options(non_neg_integer() | nil, term()) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def inner_options(nil, strategy), do: inner_options(0, strategy)

  def inner_options(timeout, strategy) when is_integer(timeout) and timeout >= 0 do
    retries = if strategy in [:retry, "retry"], do: 2, else: 0
    {:ok, [timeout: timeout, max_retries: retries, backoff: 0, telemetry: :full]}
  end

  def inner_options(_timeout, _strategy),
    do: {:error, Error.validation_error("Workflow timeout must be a non-negative integer")}

  @doc "Rejects inherited wrapper deadlines instead of dropping caller budgets."
  @spec validate_context(map()) :: :ok | {:error, Exception.t()}
  def validate_context(context) do
    if Map.has_key?(context, :__jido_deadline_ms__),
      do: {:error, Error.validation_error("Workflow wrapper cannot inherit a Jido deadline")},
      else: :ok
  end
end
