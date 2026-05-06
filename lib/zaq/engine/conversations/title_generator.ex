defmodule Zaq.Engine.Conversations.TitleGenerator do
  @moduledoc """
  Generates a short title for a conversation from the first user message.

  Modelled after `Zaq.Agent.ChunkTitle` — calls the configured LLM with a
  tightly constrained prompt and returns a 6-word-maximum plain-text title.

  The call is cheap (one short user turn) and is always performed
  asynchronously so it never blocks the message-storage path.
  """

  require Logger

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System
  alias Zaq.Utils.TextUtils

  @max_words 6

  @doc """
  Generates a concise title from the first user message of a conversation.

  ## Examples

      iex> TitleGenerator.generate("How do I reset my password in the admin panel?")
      {:ok, "Admin Panel Password Reset"}
  """
  def generate(user_message, opts \\ []) do
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

    cfg = System.get_llm_config()
    gen_opts = ProviderSpec.generation_opts(cfg) |> Keyword.delete(:top_p)

    model_spec =
      case Keyword.fetch(opts, :model) do
        {:ok, model} -> ProviderSpec.build(cfg) |> Map.put(:id, model)
        :error -> ProviderSpec.build(cfg)
      end

    case Generation.generate_text(model_spec, [Context.user(prompt)], gen_opts) do
      {:ok, response} -> response |> Response.text() |> build_title()
      {:error, reason} -> log_error(reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_title(nil) do
    Logger.error("TitleGenerator failed: Empty assistant response content")
    {:error, "Empty assistant response content"}
  end

  defp build_title(text) do
    title =
      text
      |> TextUtils.normalize_generated_title(@max_words)

    if title == "" do
      Logger.error("TitleGenerator failed: Empty assistant response content")
      {:error, "Empty assistant response content"}
    else
      Logger.info("TitleGenerator: generated \"#{title}\"")
      {:ok, title}
    end
  end

  defp log_error(reason) do
    Logger.error("TitleGenerator failed: #{inspect(reason)}")
    {:error, inspect(reason)}
  end
end
