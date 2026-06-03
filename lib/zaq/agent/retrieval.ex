defmodule Zaq.Agent.Retrieval do
  @moduledoc """
  Query rewriting agent.

  Takes a user question (plus optional conversation history) and rewrites it
  into one or more search queries via LLM, returning structured JSON.

  Uses DB-managed system prompt (`retrieval` slug) and provider-agnostic
  LLM configuration from `Zaq.Agent.Factory`.
  """

  require Logger

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.{History, ProviderSpec}
  alias Zaq.System

  @doc """
  Rewrites a user question into structured search queries via LLM.

  ## Options

    * `:system_prompt` — override the DB prompt (useful for tests).
      Defaults to the active `"retrieval"` prompt template.
    * `:history` — conversation history (map of `{timestamp, %{"body" => ..., "type" => ...}}`).

  Returns `{:ok, decoded_json}` on success.
  """
  def ask(question, opts \\ []) do
    Logger.info("Retrieval: Received question: #{question}")

    # This is intentionally hardcoded because we don't want to expose the flexibility of changing the prompt structure
    system_prompt = """
    You are a professional vector search expert tasked with building an optimal semantic query.

    LANGUAGE RULES (VERY IMPORTANT)
    - The **Query** you generate MUST ALWAYS be in English, even if the user writes in another language.
    - Detect the language of the last user message and set it in **Language**. Default to "eng" if unsure.
    - **Positive Answer** and **Negative Answer** must be written in the detected language.

    Based on the conversation, reply in this exact format and nothing else:

    **Query:** <one line of English search keywords>
    **Language:** <ISO 639-3 code only, e.g. "eng". No extra text.>
    **Positive Answer:** <friendly message inviting the user to wait while an answer is being formulated>
    **Negative Answer:** <short friendly message explaining no information was found, suggest rephrasing>
    """

    history =
      Keyword.get(opts, :history, [])
      |> History.build()

    cfg = System.get_llm_config()

    gen_opts =
      cfg
      |> ProviderSpec.generation_opts()
      |> Keyword.put(:system_prompt, system_prompt)

    Logger.info("Retrieval: Processing question history_length=#{length(history)}")

    messages =
      if question && question != "" do
        history ++ [Context.user(question)]
      else
        history
      end

    result =
      try do
        Generation.generate_text(ProviderSpec.build(cfg), messages, gen_opts)
      rescue
        e -> {:error, e}
      end

    case result do
      {:ok, response} ->
        case normalized_text(Response.text(response)) do
          nil ->
            reason = "Failed to process question: Empty assistant response content"
            Logger.error("Retrieval failed: #{reason}")
            {:error, reason}

          content ->
            decode_retrieval_content(content, question)
        end

      {:error, reason} ->
        Logger.error("Retrieval failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp decode_retrieval_content(content, original_question) do
    query = parse_md_field(content, "Query") || original_question
    language = parse_md_field(content, "Language") |> parse_language_code()
    positive_answer = parse_md_field(content, "Positive Answer")
    negative_answer = parse_md_field(content, "Negative Answer")

    {:ok,
     %{
       "query" => query,
       "language" => language,
       "positive_answer" => positive_answer,
       "negative_answer" => negative_answer
     }}
  end

  # Extracts the value after "**Field:**" on a single line, trimmed.
  defp parse_md_field(text, field) do
    case Regex.run(~r/\*\*#{Regex.escape(field)}:\*\*\s*(.+)/u, text, capture: :all_but_first) do
      [value] -> String.trim(value)
      nil -> nil
    end
  end

  # Takes only the first word (the ISO 639-3 code) and drops any trailing prose.
  defp parse_language_code(nil), do: "eng"

  defp parse_language_code(value) do
    value |> String.split() |> List.first() |> then(&(&1 || "eng"))
  end

  # coveralls-ignore-next-line
  defp normalized_text(nil), do: nil

  defp normalized_text(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)
end
