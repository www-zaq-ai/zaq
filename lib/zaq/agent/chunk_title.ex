defmodule Zaq.Agent.ChunkTitle do
  @moduledoc """
  Generates concise, searchable titles for document chunks.
  Focuses on key entities, topics, and facts to improve embedding quality.
  """

  require Logger

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.Factory
  alias Zaq.Utils.TextUtils

  @behaviour Zaq.Agent.ChunkTitleBehaviour

  @max_words 8

  @doc """
  Generates a descriptive title for a document chunk.

  ## Examples

      iex> ChunkTitle.ask("Welcome to Northwind Industries! Founded in 1987 by Eleanor Vance...")
      {:ok, "Northwind Industries Founded 1987 Eleanor Vance"}
  """
  def ask(content, _opts \\ []) do
    Logger.info("ChunkTitle: Generating title for chunk")

    prompt = """
    Generate a short title (maximum #{@max_words} words) for this document chunk.

    RULES:
    1. Output ONLY the title - no explanations, no quotes, no extra text
    2. Include key entities: company names, people names, dates, product names
    3. Focus on the main topic and specific facts
    4. Use title case
    5. Do NOT use generic titles like "Welcome Message", "Overview", "Introduction"

    GOOD examples:
    - "Northwind Industries Founder Eleanor Vance 1987"
    - "401k Matching Policy 5 Percent Maximum"
    - "Type 2 Diabetes Diagnostic Criteria HbA1c"

    BAD examples:
    - "Welcome Message"
    - "Company Overview"
    - "Introduction to Benefits"

    Content:
    #{content}
    """

    gen_opts = Factory.generation_opts() |> Keyword.delete(:top_p)

    case Generation.generate_text(Factory.build_model_spec(), [Context.user(prompt)], gen_opts) do
      {:ok, response} ->
        case normalized_text(Response.text(response)) do
          nil ->
            error_reason = "Failed to generate title: Empty assistant response content"
            Logger.error("ChunkTitle failed: #{error_reason}")
            {:error, error_reason}

          text ->
            title =
              text
              |> String.trim()
              |> remove_quotes()
              |> remove_prefix()
              |> enforce_word_limit(@max_words)

            Logger.info("ChunkTitle: Generated title: #{title}")
            {:ok, title}
        end

      {:error, reason} ->
        error_reason = "Failed to generate title: #{inspect(reason)}"
        Logger.error("ChunkTitle failed: #{error_reason}")
        {:error, error_reason}
    end
  end

  @doc """
  Returns the maximum number of words allowed in a chunk title.
  """
  def max_words, do: @max_words

  # Remove surrounding quotes
  defp remove_quotes(text) do
    text
    |> String.replace(~r/^["']/, "")
    |> String.replace(~r/["']$/, "")
    |> String.trim()
  end

  # Remove common prefixes that LLMs might add
  defp remove_prefix(text) do
    text
    |> String.replace(~r/^(Title:|Here is|Here's|The title is:?)\s*/i, "")
    |> String.trim()
  end

  defp enforce_word_limit(text, max_words), do: TextUtils.enforce_word_limit(text, max_words)

  defp normalized_text(nil), do: nil

  defp normalized_text(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)
end
