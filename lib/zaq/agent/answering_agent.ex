defmodule Zaq.Agent.AnsweringAgent do
  @moduledoc """
  Transient Jido AI agent used by `Zaq.Agent.Answering` to formulate answers
  using a ReAct loop with knowledge base tools.

  Started per-request (start_link) and stopped after the response is received.
  """

  use Jido.AI.Agent,
    name: "answering_agent",
    description: "Formulates answers from retrieved ZAQ knowledge base context",
    request_policy: :reject,
    tools: [
      Zaq.Agent.Tools.SearchKnowledgeBase,
      Zaq.Agent.Tools.AskForClarification
    ]

  def strategy_opts do
    super()
    |> Keyword.delete(:model)
  end
end
