defmodule Zaq.Agent.Answering do
  @moduledoc """
  Response formulation agent.

  Receives context (retrieved chunks + user question) via a system prompt and
  generates a natural answer. Optionally computes a confidence score from
  logprobs when the LLM provider supports it.

  Uses DB-managed system prompt (`answering` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.LLM`.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Utils.ChainResult
  alias Zaq.Agent.{LLM, LogprobsAnalyzer}

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

  @doc """
  Generates an answer from the given system prompt (which should include
  retrieved context) and optional conversation history.

  ## Options

    * `:system_prompt` — override the DB prompt. When omitted, loads the
      active `"answering"` template and renders it.
    * `:history` — conversation history map.
    * `:include_confidence` — whether to compute logprobs confidence.
      Defaults to `true` when the LLM supports logprobs, `false` otherwise.

  ## Returns

    * `{:ok, %{answer: String.t(), confidence: %{score: float()}}}` — when confidence is included
    * `{:ok, String.t()}` — when confidence is not included
    * `{:error, String.t()}` — on failure
  """
  def ask(system_prompt, opts \\ []) do
    include_confidence =
      Keyword.get(opts, :include_confidence, LLM.supports_logprobs?())

    history =
      Keyword.get(opts, :history, [])
      |> build_history()

    llm_config =
      LLM.chat_config()
      |> maybe_add_logprobs(include_confidence)

    Logger.info("Answering: Formulating response based on retrieved data")

    try do
      {:ok, updated_chain} =
        LLMChain.new!(%{llm: ChatOpenAI.new!(llm_config)})
        |> LLMChain.add_message(Message.new_system!(system_prompt))
        |> then(fn chain ->
          if history != [], do: LLMChain.add_messages(chain, history), else: chain
        end)
        |> LLMChain.run()

      answer = ChainResult.to_string!(updated_chain)

      if include_confidence do
        bot_response = updated_chain.messages |> List.last()
        logprobs_content = bot_response.metadata.logprobs["content"]
        input_token_usage = bot_response.metadata.usage.input
        output_token_usage = bot_response.metadata.usage.output

        score = LogprobsAnalyzer.calculate_confidence(logprobs_content, true)
        Logger.info("Response confidence: #{score * 100}%")
        Logger.info("Input tokens: #{input_token_usage}")
        Logger.info("Output tokens: #{output_token_usage}")

        {:ok, %{answer: answer, confidence: %{score: score}}}
      else
        {:ok, answer}
      end
    rescue
      e ->
        Logger.error("Answering failed: #{inspect(e)}")
        {:error, "Failed to formulate response: #{Exception.message(e)}"}
    end
  end

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

  # -- Private --

  defp build_history([]), do: []

  defp build_history(history) when is_map(history) do
    Enum.map(history, fn
      {_timestamp, %{"body" => msg, "type" => "bot"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_assistant!(msg)

      {_timestamp, %{"body" => msg, "type" => "user"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Message.new_user!(msg)
    end)
  end

  defp maybe_add_logprobs(config, true), do: Map.put(config, :logprobs, true)
  defp maybe_add_logprobs(config, false), do: config
end
