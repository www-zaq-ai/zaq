defmodule Zaq.Agent.Actions.EvaluateDecisions do
  @moduledoc """
  Evaluates supplied JSON state against named questions using the global decision model.

  Workflows and explicitly enabled agent tools share this operation. It fetches no
  additional data and a decision never grants permission. Missing configuration,
  provider refusals and incomplete answers fail the whole invocation. Inference
  has no automatic retries; repeated calls may incur charges and differ in result.
  The callback validates its domain input as well, because workflow StepRunner
  invokes callbacks within its own execution lifecycle rather than through Exec.

  Trusted callers may supply a monotonic millisecond `decision_deadline` in context.
  Otherwise the external call has a 30-second total deadline. Jido owns the outer
  execution, cancellation and tracing lifecycle.
  """

  alias Jido.Action.Error, as: ActionError
  alias Jido.Action.Schema, as: ActionSchema
  alias Jido.Action.Tool
  alias Zaq.Agent.DecisionContract
  alias Zaq.Agent.ErrorMessage
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System

  use Zaq.Engine.Workflows.Action,
    name: "evaluate_decisions",
    description: """
    Evaluate supplied state with the globally configured decision model. Ask named
    boolean, choice or ordered-rubric score questions in one call. Returns decisions
    with type/value, optional alternative probabilities and confidence. Scores may
    be fractional rubric indices. This does not fetch data or authorize actions.
    Every question needs type and instructions. For choice, criteria maps option IDs
    to descriptions, e.g. {"type":"choice","instructions":"Classify feedback",
    "criteria":{"bug":"A defect","compliment":"Praise"}}. For boolean, use
    {"type":"boolean","instructions":"Should support intervene?"}; threshold is
    optional (default 0.5). For score, criteria is an ordered list of rubric labels.
    Do not use options, question strings, or criteria on boolean questions.
    """,
    schema: DecisionContract.tool_schema(),
    output_schema: DecisionContract.output_schema()

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    case DecisionContract.prepare_input(params) do
      {:ok, normalized} ->
        input_schema = DecisionContract.input_schema()
        converted = Tool.convert_params_using_schema(normalized, input_schema)

        case Zoi.parse(input_schema, converted) do
          {:ok, validated} -> {:ok, validated}
          {:error, errors} -> {:error, ActionSchema.format_error(errors, "Action", __MODULE__)}
        end

      {:error, _} ->
        {:error, ActionError.validation_error("Invalid decision input")}
    end
  end

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(params, context) do
    with {:ok, validated} <- validate_params(params) do
      evaluate_params(validated, context)
    end
  end

  defp evaluate_params(%{state: state, questions: questions}, context) do
    with {:runtime, {:ok, model, opts}} <-
           {:runtime,
            ProviderSpec.operation_runtime(System.get_decision_model_config(), :evaluation)},
         {:deadline, {:ok, timeout}} <- {:deadline, remaining_timeout(context)},
         {:request, {:ok, response}} <-
           {:request, evaluate(model, opts, state, questions, timeout)},
         {:response, {:ok, answers}} <-
           {:response, DecisionContract.normalize_answers(response.object, questions)} do
      {:ok, %{decisions: answers}}
    else
      {stage, {:error, reason}} -> failure(stage, reason)
    end
  rescue
    _error -> failure(:runtime, :unexpected_exception)
  end

  defp remaining_timeout(context) do
    now = Elixir.System.monotonic_time(:millisecond)
    timeout = min(Map.get(context, :decision_deadline, now + 30_000) - now, 30_000)
    if timeout > 0, do: {:ok, timeout}, else: {:error, :timeout}
  end

  defp evaluate(model, opts, state, questions, timeout) do
    wire_questions =
      Map.new(questions, fn {id, question} -> {id, Map.delete(question, "threshold")} end)

    ReqLLM.evaluate(
      model,
      state,
      wire_questions,
      Keyword.merge(opts,
        max_retries: 0,
        total_timeout: timeout,
        receive_timeout: timeout
      )
    )
  end

  defp failure(_stage, :model_not_configured), do: error("decision_model_not_configured")
  defp failure(_stage, :refused), do: error("decision_refused")
  defp failure(:response, _reason), do: error("decision_response_invalid")

  defp failure(stage, reason) do
    diagnostic = ErrorMessage.diagnostic_for(reason)

    code =
      cond do
        diagnostic.reason == :timeout ->
          "decision_timeout"

        diagnostic[:http_status] in [401, 403] or
            ErrorMessage.recovery_for(reason) in [:personal_credentials, :contact_administrator] ->
          "decision_authentication_failed"

        stage == :runtime ->
          "decision_model_unsupported"

        diagnostic.reason in [:invalid_response, :provider_response_failed] ->
          "decision_response_invalid"

        true ->
          "decision_request_failed"
      end

    error(code)
  end

  defp error(code), do: {:error, ActionError.execution_error(code, %{retry: false})}
end
