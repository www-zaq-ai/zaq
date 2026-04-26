defmodule Zaq.Agent.Executor do
  @moduledoc """
  Single execution boundary for all agent runs.

  Handles both the default answering path (when no agent is selected) and
  explicit BO-configured agents. Responsible for scope derivation, Jido server
  lifecycle, typing indicators, telemetry, and result normalization.
  """

  require Logger

  alias Zaq.Agent
  alias Zaq.Agent.{Answering, Factory, LogprobsAnalyzer, ServerManager}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Telemetry

  @spec derive_scope(Incoming.t()) :: String.t()
  def derive_scope(%Incoming{person_id: person_id}) when not is_nil(person_id),
    do: to_string(person_id)

  def derive_scope(%Incoming{metadata: %{session_id: sid}}) when is_binary(sid) and sid != "",
    do: sid

  def derive_scope(_), do: "anonymous"

  @spec run(Incoming.t(), keyword()) :: Outgoing.t()
  def run(%Incoming{} = incoming, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    agent_module = Keyword.get(opts, :agent_module, Agent)
    server_manager_module = Keyword.get(opts, :server_manager_module, ServerManager)
    factory_module = Keyword.get(opts, :factory_module, Factory)
    dims = telemetry_dimensions(opts, incoming)

    :ok = Telemetry.record("qa.message.count", 1, dims)
    :ok = Telemetry.record("qa.custom_agent.execution.start", 1, dims)

    question = Keyword.get(opts, :question, incoming.content)

    opts = ensure_scope_for_answering_path(opts, incoming)

    result =
      with {:ok, configured_agent} <-
             load_selected_agent(opts, agent_module, factory_module),
           configured_agent <- apply_system_prompt_override(configured_agent, opts),
           {:ok, server_id} <- ensure_agent_server(server_manager_module, configured_agent, opts),
           node_router(opts).call(:channels, Zaq.Channels.Router, :send_typing, [
             incoming.provider,
             incoming.channel_id
           ]),
           {:ok, request} <-
             factory_module.ask_with_config(server_id, question, configured_agent,
               context: %{
                 person_id: Keyword.get(opts, :person_id),
                 team_ids: Keyword.get(opts, :team_ids, [])
               }
             ),
           {:ok, answer} <- factory_module.await(request, timeout: 45_000) do
        confidence =
          LogprobsAnalyzer.confidence_from_metadata_or_nil(%{
            logprobs: LogprobsAnalyzer.from_response(answer)
          })

        result = success_result(answer, configured_agent, started_at, confidence)
        :ok = record_success_telemetry(result, dims)
        Outgoing.from_pipeline_result(incoming, result)
      else
        {:error, reason} ->
          Logger.error("Configured agent execution failed: #{inspect(reason)}")

          :ok =
            Telemetry.record(
              "qa.custom_agent.execution.error",
              1,
              Map.put(dims, :error_type, error_type(reason))
            )

          Outgoing.from_pipeline_result(incoming, error_result(reason))
      end

    result
  end

  defp ensure_agent_server(server_manager_module, configured_agent, opts) do
    case Keyword.get(opts, :scope) do
      nil ->
        server_manager_module.ensure_server(configured_agent)

      scope ->
        server_id = "#{configured_agent.name}:#{scope}"
        server_manager_module.ensure_server_by_id(configured_agent, server_id)
    end
  end

  defp load_selected_agent(opts, agent_module, _factory_module) do
    answering_module = Keyword.get(opts, :answering_module, Answering)

    case Keyword.get(opts, :agent_id) do
      nil -> {:ok, answering_module.answering_configured_agent()}
      agent_id -> agent_module.get_active_agent(agent_id)
    end
  end

  defp ensure_scope_for_answering_path(opts, incoming) do
    if Keyword.get(opts, :agent_id) == nil and Keyword.get(opts, :scope) == nil do
      Keyword.put(opts, :scope, derive_scope(incoming))
    else
      opts
    end
  end

  defp apply_system_prompt_override(configured_agent, opts) do
    case Keyword.get(opts, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> %{configured_agent | job: prompt}
      _ -> configured_agent
    end
  end

  defp success_result(answer, configured_agent, started_at, confidence) do
    answer_text = normalize_answer(answer)
    metrics = extract_metrics(answer, started_at)

    %{
      answer: answer_text,
      confidence_score: confidence || metrics.confidence_score,
      latency_ms: metrics.latency_ms,
      prompt_tokens: metrics.prompt_tokens,
      completion_tokens: metrics.completion_tokens,
      total_tokens: metrics.total_tokens,
      error: false,
      configured_agent_id: configured_agent.id,
      configured_agent_name: configured_agent.name,
      sources: []
    }
  end

  defp error_result(reason) do
    %{
      answer: "Sorry, something went wrong while executing the selected agent.",
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true,
      reason: inspect(reason),
      sources: []
    }
  end

  defp normalize_answer(%{result: result}), do: normalize_answer(result)
  defp normalize_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_answer(answer) when is_binary(answer), do: answer
  defp normalize_answer(other), do: inspect(other)

  defp extract_metrics(answer, started_at) do
    usage = find_usage(answer)

    %{
      latency_ms: System.monotonic_time(:millisecond) - started_at,
      prompt_tokens: usage_value(usage, [:prompt_tokens, :input_tokens]),
      completion_tokens: usage_value(usage, [:completion_tokens, :output_tokens]),
      total_tokens: usage_value(usage, [:total_tokens]),
      confidence_score: nil
    }
  end

  defp find_usage(%{usage: usage}) when is_map(usage), do: usage
  defp find_usage(%{"usage" => usage}) when is_map(usage), do: usage
  defp find_usage(%{result: result}), do: find_usage(result)
  defp find_usage(%{"result" => result}), do: find_usage(result)
  defp find_usage(_), do: %{}

  defp usage_value(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(usage, key) || Map.get(usage, to_string(key)) do
        value when is_integer(value) -> value
        _ -> nil
      end
    end)
  end

  defp record_success_telemetry(result, dims) do
    :ok = Telemetry.record("qa.custom_agent.execution.complete", 1, dims)
    :ok = Telemetry.record("qa.answer.count", 1, dims)

    if is_integer(result.latency_ms),
      do: Telemetry.record("qa.answer.latency_ms", result.latency_ms, dims),
      else: :ok

    if is_integer(result.prompt_tokens),
      do: Telemetry.record("qa.tokens.prompt", result.prompt_tokens, dims),
      else: :ok

    if is_integer(result.completion_tokens),
      do: Telemetry.record("qa.tokens.completion", result.completion_tokens, dims),
      else: :ok

    if is_integer(result.total_tokens),
      do: Telemetry.record("qa.tokens.total", result.total_tokens, dims),
      else: :ok

    :ok
  end

  defp telemetry_dimensions(opts, incoming) do
    opts
    |> Keyword.get(:telemetry_dimensions, %{})
    |> Map.merge(%{
      provider: incoming.provider,
      channel_id: incoming.channel_id,
      execution_path: "custom_agent"
    })
  end

  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type(%{__struct__: mod}), do: inspect(mod)
  defp error_type(_), do: "unknown"

  defp node_router(opts) do
    Keyword.get(
      opts,
      :node_router,
      Application.get_env(:zaq, :pipeline_node_router_module, Zaq.NodeRouter)
    )
  end
end
