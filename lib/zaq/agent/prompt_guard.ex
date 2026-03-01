defmodule Zaq.Agent.PromptGuard do
  @moduledoc """
  Security guards to prevent prompt injection and system prompt leakage.

  Use `validate/1` at the entry point before the question reaches any agent.
  Use `output_safe?/1` to check LLM responses before returning them to the user.

  ## Flow

      User question
        → PromptGuard.validate/1        ← blocks injection here
        → Retrieval.ask/2               ← LLM call
        → Answering.ask/2               ← LLM call
        → PromptGuard.output_safe?/1    ← catches leaks here
        → User
  """

  @blocked_patterns [
    # Prompt extraction
    ~r/ignore\s+(?:(?:all|previous|above)\s+)*(instructions|prompts|rules)/i,
    ~r/reveal\s+(?:your\s+|the\s+)?(?:system|initial|original)\s*(?:prompt|instructions)/i,
    ~r/what\s+(?:are|is)\s+your\s+(?:system\s+|original\s+)?(?:prompt|instructions|rules)/i,
    ~r/repeat\s+(?:everything|all|the\s+text)\s+(?:above|back)/i,
    ~r/output\s+(?:your|the)\s+(?:system|initial)\s*(?:prompt|message|instructions)/i,
    ~r/print\s+(?:your|the)\s+(?:system|above|initial)\s*(?:prompt|text|instructions)/i,
    ~r/show\s+(?:me\s+)?(?:your\s+)?(?:system|hidden|internal)\s*(?:prompt|instructions|config)/i,

    # Jailbreak / persona hijacking
    ~r/you\s+are\s+now\s+/i,
    ~r/act\s+as\s+(?:a\s+)?DAN/i,
    ~r/pretend\s+you\s+(?:are|have)\s+no\s+restrict/i,
    ~r/jailbreak/i,
    ~r/bypass\s+(?:your\s+)?(?:rules|restrictions|filters|guidelines)/i,
    ~r/enter\s+(?:developer|debug|admin)\s+mode/i,

    # Instruction override / injection
    ~r/new\s+instructions?\s*:/i,
    ~r/system\s*prompt\s*:/i,
    ~r/\]\s*\}\s*system/i,
    ~r/<\/?system>/i,

    # Query manipulation targeting retrieval / data exfiltration
    ~r/return\s+(?:all|every)\s+(?:documents?|results?|records?)/i,
    ~r/dump\s+(?:all|the)\s+(?:the\s+)?(?:data|documents?|database|index)/i,
    ~r/list\s+(?:all|every)\s+(?:available\s+)?(?:sources?|files?|documents?)/i
  ]

  @default_sensitive_phrases [
    # Agent internals
    "response formulation agent",
    "HIDDEN ADVANCED REASONING",
    "Decision-Making Framework",
    "chain-of-thought",
    "retrieved_data"
  ]

  @role_play_signals [
    "from now on",
    "new persona",
    "you must obey",
    "override",
    "forget everything",
    "disregard",
    "do not follow"
  ]

  @role_play_threshold 2

  # -- Public API --

  @doc """
  Validates user input before it enters the agent pipeline.
  Returns `{:ok, input}` or `{:error, reason}`.

  ## Example

      case PromptGuard.validate(question) do
        {:ok, clean_input} ->
          Retrieval.ask(clean_input, opts)

        {:error, :prompt_injection} ->
          {:error, "I can't process that request."}
      end
  """
  def validate(input) when is_binary(input) do
    cond do
      injection_detected?(input) ->
        {:error, :prompt_injection}

      excessive_role_play?(input) ->
        {:error, :role_play_attempt}

      true ->
        {:ok, input}
    end
  end

  def validate(_), do: {:error, :invalid_input}

  @doc """
  Checks if LLM output accidentally leaked parts of the system prompt.
  Call this on the final answer before returning it to the user.

  Accepts an optional list of sensitive phrases to check against.
  Defaults to built-in phrases.
  """
  def output_safe?(output, sensitive_phrases \\ @default_sensitive_phrases) do
    normalized = String.downcase(output)

    leaked =
      Enum.find(sensitive_phrases, fn phrase ->
        String.contains?(normalized, String.downcase(phrase))
      end)

    case leaked do
      nil -> {:ok, output}
      phrase -> {:error, {:leaked, phrase}}
    end
  end

  # -- Private --

  defp injection_detected?(input) do
    Enum.any?(@blocked_patterns, fn pattern ->
      Regex.match?(pattern, input)
    end)
  end

  defp excessive_role_play?(input) do
    lowered = String.downcase(input)

    count =
      Enum.count(@role_play_signals, &String.contains?(lowered, &1))

    count >= @role_play_threshold
  end
end
