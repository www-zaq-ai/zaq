defmodule Zaq.Agent.Tools.AskForClarification do
  @moduledoc """
  ReAct tool: signals that the user's question is ambiguous and returns a
  clarifying question to be surfaced to the user.
  """

  use Jido.Action,
    name: "ask_for_clarification",
    description: """
    Use this tool when the user's question is ambiguous or could have multiple
    valid interpretations and a clarifying question would lead to a better answer.
    Do NOT use this as a substitute for searching when context is simply missing.
    """,
    schema: [
      reason: [type: :string, required: true, doc: "Why clarification is needed"],
      question: [type: :string, required: true, doc: "The clarifying question to ask the user"]
    ]

  def run(%{reason: reason, question: question}, _context) do
    {:ok, %{clarification_needed: true, reason: reason, question: question}}
  end
end
