defmodule Zaq.Engine.Conversations.TitleGenerator do
  @moduledoc """
  Generates a short title for a conversation from the first user message.

  Modelled after `Zaq.Agent.ChunkTitle` — calls the configured LLM with a
  tightly constrained prompt and returns a 6-word-maximum plain-text title.

  The call is cheap (one short user turn) and is always performed
  asynchronously so it never blocks the message-storage path.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.Message
  alias Zaq.Agent.{LLM, LLMRunner}
  alias Zaq.Utils.TextUtils

  @max_words 6

  @doc """
  Generates a concise title from the first user message of a conversation.

  ## Options

    * `:model` — override the configured LLM model.

  ## Examples

      iex> TitleGenerator.generate("How do I reset my password in the admin panel?")
      {:ok, "Admin Panel Password Reset"}
  """
  def generate(user_message, opts \\ []) do
    llm_config =
      LLM.chat_config(Keyword.take(opts, [:model]))
      |> Map.drop([:top_p])

    prompt = """
    Generate a short title (maximum #{@max_words} words) for a conversation that starts with this user message. Keep in mind that user is communicating with ZAQ.

    RULES:
    1. Output ONLY the title — no explanations, no quotes, no extra text
    2. Be specific: capture the main topic or question
    3. Use title case
    4. Do NOT use generic titles like "User Question" or "Conversation"

    GOOD examples:
    - "Admin Panel Password Reset Steps"
    - "Q4 Sales Report Analysis"
    - "Onboarding Checklist New Employees"

    BAD examples:
    - "Question About System"
    - "Help Request"
    - "User Question"

    First user message:
    #{user_message}
    """

    try do
      {:ok, updated_chain} =
        LLMChain.new!(%{llm: build_llm_model(llm_config)})
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      case LLMRunner.content_result(updated_chain) do
        {:ok, content} ->
          title =
            content
            |> String.trim()
            |> remove_quotes()
            |> remove_prefix()
            |> enforce_word_limit(@max_words)

          Logger.info("TitleGenerator: generated \"#{title}\"")
          {:ok, title}

        {:error, reason} ->
          Logger.error("TitleGenerator failed: #{reason}")
          {:error, reason}
      end
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_llm_model(%{provider: "anthropic"} = config) do
    ChatAnthropic.new!(%{
      model: config.model,
      temperature: config.temperature,
      api_key: config.api_key,
      endpoint: config.endpoint
    })
  end

  defp build_llm_model(config) do
    ChatOpenAI.new!(config)
  end

  defp remove_quotes(text) do
    text
    |> String.replace(~r/^["']/, "")
    |> String.replace(~r/["']$/, "")
    |> String.trim()
  end

  defp remove_prefix(text) do
    text
    |> String.replace(~r/^(Title:|Here is|Here's|The title is:?)\s*/i, "")
    |> String.trim()
  end

  defp enforce_word_limit(text, max), do: TextUtils.enforce_word_limit(text, max)
end
