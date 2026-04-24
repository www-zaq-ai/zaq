defmodule Zaq.Agent.Answering do
  @moduledoc """
  Answering agent constants and helpers.

  Defines the tools list and no-answer signals used by the answering agent.
  Execution is handled by `Zaq.Agent.Executor` via `Factory.answering_configured_agent/0`.
  """

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
end
