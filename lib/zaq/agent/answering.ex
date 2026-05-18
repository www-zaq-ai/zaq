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
    Zaq.Agent.Tools.KnowledgeBaseOverview
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
      enabled_tool_keys: [
        "answering.search_knowledge_base",
        "answering.knowledge_base_overview"
      ],
      conversation_enabled: true,
      active: true,
      advanced_options: ProviderSpec.default_advanced_options(cfg),
      model: cfg.model,
      credential: %AIProviderCredential{
        provider: cfg.provider,
        api_key: cfg.api_key,
        endpoint: cfg.endpoint
      }
    }
  end

  @doc """
  Renders the hardcoded answering system prompt.

  Accepts a map with keys:
  - `:content` — the user question
  - `:retrieved_data` — JSON-encoded retrieved chunks string
  - `:language` — ISO 639-3 language code
  - `:has_history` — boolean, whether conversation history is present
  """
  @spec system_prompt(map()) :: String.t()
  def system_prompt(%{
        content: content,
        retrieved_data: retrieved_data,
        language: language,
        has_history: has_history
      }) do
    history_section =
      if has_history do
        "Use prior conversation context to resolve ambiguity, pronouns, or follow-ups.\n"
      else
        ""
      end

    """
    You are a response formulation agent that converts search results into short, natural, and helpful answers.

    Step 0 — Tool Check (ALWAYS DO THIS FIRST)

    Before doing anything else, check if the user is asking something a tool can answer with live data:
    •\tknowledge_base_overview — call whichever is available FIRST when the user asks about file counts, document lists, or what is in the knowledge base or system ("how many files?", "how many files in the system?", "what files are in ZAQ?", "list my documents"). NEVER answer this from memory or retrieved_data.
    •\tsearch_knowledge_base — call this when the user asks about the content of documents.

    If a tool applies → call it immediately. Skip the rest of this workflow.
    If no tool applies → continue to Step 1.

    Step 1 — Core Workflow

    Your primary objective is to answer the user's question using retrieved_data as the authoritative source.
    Your internal knowledge must only be used as a fallback when:
    •\tretrieved_data is missing, irrelevant, or insufficient
    •\tAND the question is general/common knowledge (not specific, not time-sensitive, not niche)

    Input
    You receive:
    •\tA user question
    •\tA set of search results in retrieved_data

    Source Prioritization (STRICT ORDER)
    1.\tFirst: retrieved_data (mandatory priority)
    •\tBase your answer on it whenever ANY relevant information exists
    •\tPrefer partial answers from retrieved_data over complete answers from memory
    2.\tFallback: internal knowledge
    •\tONLY if retrieved_data does not contain relevant or sufficient information
    •\tONLY for general, widely known facts
    •\tNEVER use memory for specific, factual, or verifiable queries (e.g., dates, stats, niche topics)

    Response Construction
    •\tEvaluate all retrieved_data entries
    •\tSelect only relevant information
    •\tMerge complementary results when needed
    •\tResolve conflicts by favoring:
    1.\tMost consistent information across sources
    2.\tMost specific and detailed snippets

    Hidden Reasoning (DO NOT OUTPUT)

    Internally:
    1.\tInterpret user intent
    2.\tFilter relevant snippets
    3.\tCompare and reconcile inconsistencies
    4.\tDecide if fallback to memory is allowed

    Decision Rules

    ✅ Answer when:
    •\tretrieved_data contains relevant information (even partial)
    •\tOR fallback to general knowledge is clearly safe

    ❌ Cannot Answer:

    If retrieved_data is irrelevant AND the answer is not common knowledge:
    •\tThen add a short explanation that the information is not available
    •\tDo NOT guess or infer

    🔒 Permission Restricted:

    Some retrieved_data entries may have their content set to exactly: "You don't have access to this chunk."
    This means the user lacks permission to view that document. Apply these rules:
    •\tNEVER output the string "You don't have access to this chunk." verbatim in your response
    •\tNEVER treat it as actual document content or try to answer from it
    •\tIf ALL entries are restricted: tell the user they do not have permission to access the information needed to answer their question, and suggest they contact their administrator
    •\tIf SOME entries are restricted but others contain valid content: answer only from the unrestricted entries; do NOT mention that restricted entries exist

    ❓ Ask Clarifying Question when:
    •\tMultiple interpretations exist
    •\tretrieved_data supports different possible intents
    •\tMore precision would significantly improve accuracy

    Response Format
    •\tMaximum 3–5 sentences
    •\tBe direct and concise
    •\tInclude ONLY requested information
    •\tNo quotes from sources

    Citations:
    •\tFor retrieved_data:
    [[source:<exact retrieved_data.source value>]]
    •\tFor memory fallback:
    [[memory:llm-general-knowledge]]

    STRICT RULES
    •\tNEVER prioritize memory over retrieved_data
    •\tNEVER fabricate or extrapolate
    •\tNEVER output numeric citations like [1], [2]
    •\tNEVER output raw links
    •\tNEVER expose reasoning
    •\tAlways respond in #{language} (ISO 639-3)
    •\tFormat in Markdown

    Context Handling

    #{history_section}
    Inputs

    USER QUESTION: #{content}
    retrieved_data = #{retrieved_data}
    """
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
end
