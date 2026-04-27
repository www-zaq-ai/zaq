defmodule Zaq.Agent.Answering do
  @moduledoc """
  Answering agent constants, helpers, and default configuration.

  Defines the tools list, no-answer signals, and the built-in answering
  `ConfiguredAgent` used when no BO-configured agent is selected.
  Execution is handled by `Zaq.Agent.Executor`.
  """

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System
  alias Zaq.System.AIProviderCredential

  @answering_tools [
    Zaq.Agent.Tools.SearchKnowledgeBase,
    Zaq.Agent.Tools.AskForClarification
  ]

  @no_answer_signals [
    "i don't have",
    "i do not have",
    "no information",
    "not enough information",
    "i cannot answer",
    "i can't answer",
    "no relevant",
    "outside my knowledge"
  ]

  @doc "Returns the answering tools list."
  def answering_tools, do: @answering_tools

  @doc "Returns the no-answer signal strings used by LogprobsAnalyzer."
  def no_answer_signals, do: @no_answer_signals

  @doc """
  Checks whether the answer indicates the agent could not find relevant info.

  Returns `true` if the answer contains any of the known no-answer signals.
  """
  @spec no_answer?(String.t()) :: boolean()
  def no_answer?(answer) when is_binary(answer) do
    downcased = String.downcase(answer)
    Enum.any?(@no_answer_signals, &String.contains?(downcased, &1))
  end

  def no_answer?(_), do: false

  @spec answering_configured_agent() :: ConfiguredAgent.t()
  def answering_configured_agent do
    cfg = System.get_llm_config()

    %ConfiguredAgent{
      id: :answering,
      name: "answering",
      strategy: "react",
      enabled_tool_keys: ["answering.search_knowledge_base", "answering.ask_for_clarification"],
      conversation_enabled: false,
      active: true,
      advanced_options: default_advanced_options(cfg),
      model: cfg.model,
      credential: %AIProviderCredential{
        provider: cfg.provider,
        api_key: cfg.api_key,
        endpoint: cfg.endpoint
      }
    }
  end

  @doc """
  Cleans up the raw LLM answer by trimming whitespace and removing
  any surrounding quotes or markdown code fences.
  """
  @spec clean_answer(String.t()) :: String.t()
  def clean_answer(answer) when is_binary(answer) do
    answer
    |> String.trim()
    |> String.replace(~r/^```[\w]*\n?/, "")
    |> String.replace(~r/\n?```$/, "")
    |> String.trim("\"")
    |> String.trim()
  end

  def clean_answer(answer), do: answer

  defp default_advanced_options(%{supports_logprobs: true} = cfg) do
    if ProviderSpec.reqllm_provider(cfg.provider) == :openai do
      %{provider_options: [openai_logprobs: true]}
      |> maybe_put_json_mode(cfg)
    else
      maybe_put_json_mode(%{}, cfg)
    end
  end

  defp default_advanced_options(cfg), do: maybe_put_json_mode(%{}, cfg)

  defp maybe_put_json_mode(opts, %{supports_json_mode: true}),
    do: Map.put(opts, :response_format, %{type: "json_object"})

  defp maybe_put_json_mode(opts, _cfg), do: opts
end
