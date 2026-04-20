defmodule Zaq.Agent.Executor do
  @moduledoc """
  Executes explicit BO-selected configured agents.
  """

  require Logger

  alias Zaq.Agent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @spec run(Incoming.t(), keyword()) :: Outgoing.t()
  def run(%Incoming{} = incoming, opts \\ []) do
    agent_module = Keyword.get(opts, :agent_module, Agent)
    server_manager_module = Keyword.get(opts, :server_manager_module, ServerManager)
    factory_module = Keyword.get(opts, :factory_module, Factory)

    with {:ok, configured_agent} <- load_selected_agent(opts, agent_module),
         {:ok, server_id} <- server_manager_module.ensure_server(configured_agent),
         {:ok, request} <-
           factory_module.ask_with_config(server_id, incoming.content, configured_agent),
         {:ok, answer} <- factory_module.await(request, timeout: 45_000) do
      Outgoing.from_pipeline_result(incoming, success_result(answer, configured_agent))
    else
      {:error, reason} ->
        Logger.error("Configured agent execution failed: #{inspect(reason)}")
        Outgoing.from_pipeline_result(incoming, error_result(reason))
    end
  end

  defp load_selected_agent(opts, agent_module) do
    case Keyword.get(opts, :agent_id) do
      nil -> {:error, :missing_agent_selection}
      agent_id -> agent_module.get_active_agent(agent_id)
    end
  end

  defp success_result(answer, configured_agent) do
    answer_text = normalize_answer(answer)

    %{
      answer: answer_text,
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
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
end
