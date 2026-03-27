defmodule Zaq.Agent.ChunkTitle do
  @moduledoc """
  Generates concise, searchable titles for document chunks.
  Focuses on key entities, topics, and facts to improve embedding quality.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Message
  alias LangChain.Message.ContentPart
  alias LangChain.Utils.ChainResult
  alias Zaq.Agent.LLM

  @behaviour Zaq.Agent.ChunkTitleBehaviour

  @max_words 8

  @doc """
  Generates a descriptive title for a document chunk.

  ## Options

    * `:model` — override the configured LLM model.

  ## Examples

      iex> ChunkTitle.ask("Welcome to Northwind Industries! Founded in 1987 by Eleanor Vance...")
      {:ok, "Northwind Industries Founded 1987 Eleanor Vance"}
  """
  def ask(content, opts \\ []) do
    llm_config =
      LLM.chat_config(Keyword.take(opts, [:model]))
      |> Map.drop([:top_p])

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

    try do
      {:ok, updated_chain} =
        LLMChain.new!(%{llm: ChatOpenAI.new!(llm_config)})
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      title =
        chain_content(updated_chain)
        |> String.trim()
        |> remove_quotes()
        |> remove_prefix()
        |> enforce_word_limit(@max_words)

      Logger.info("ChunkTitle: Generated title: #{title}")
      {:ok, title}
    rescue
      e ->
        Logger.error("ChunkTitle failed: #{inspect(e)}")
        {:error, "Failed to generate title: #{Exception.message(e)}"}
    end
  end

  @doc """
  Returns the maximum number of words allowed in a chunk title.
  """
  def max_words, do: @max_words

  defp chain_content(chain) do
    case ChainResult.to_string(chain) do
      {:ok, text} -> text
      {:error, _chain, _err} -> ContentPart.parts_to_string(chain.last_message.content)
    end
  end

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

  # Enforce word limit by truncating if necessary
  defp enforce_word_limit(text, max_words) do
    words = String.split(text, ~r/\s+/, trim: true)

    if length(words) > max_words do
      words
      |> Enum.take(max_words)
      |> Enum.join(" ")
    else
      text
    end
  end
end
