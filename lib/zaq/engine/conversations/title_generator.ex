defmodule Zaq.Engine.Conversations.TitleGenerator do
  @moduledoc """
  Generates a short title for a conversation from the first user message.

  Modelled after `Zaq.Agent.ChunkTitle` — calls the configured LLM with a
  tightly constrained prompt and returns a 6-word-maximum plain-text title.

  The call is cheap (one short user turn) and is always performed
  asynchronously so it never blocks the message-storage path.

  Title generation must never break the conversation flow. If the provider
  is unavailable, rate-limited, over budget, or returns nothing usable, this
  module derives a deterministic fallback title from the user's own message
  and returns `{:fallback, title, reason}` — the caller always gets a usable
  title, and the underlying error is surfaced (logged + carried in the tuple)
  rather than silently dropped.
  """

  require Logger

  alias ReqLLM.{Context, Generation, Response}
  alias Zaq.Agent.ProviderSpec
  alias Zaq.System
  alias Zaq.Utils.TextUtils

  @max_words 6
  @default_title "New Conversation"

  @doc """
  Generates a concise title from the first user message of a conversation.

  Returns one of:

    * `{:ok, title}` — the LLM produced a usable title.
    * `{:fallback, title, reason}` — the LLM call failed (provider error,
      rate limit, budget exceeded, empty/unusable response, or an
      unexpected exception). `title` is derived deterministically from
      `user_message` and `reason` carries the original failure so it can be
      logged or passed to the next step.

  It never returns an error tuple and never raises — a title is always
  produced so conversations are never left untitled.

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
      {:ok, response} -> response |> Response.text() |> build_title(user_message)
      {:error, reason} -> fallback(user_message, reason)
    end
  rescue
    error -> fallback(user_message, error)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_title(text, user_message) do
    title = text |> to_string() |> TextUtils.normalize_generated_title(@max_words)

    if title == "" do
      fallback(user_message, "Empty assistant response content")
    else
      Logger.info("TitleGenerator: generated \"#{title}\"")
      {:ok, title}
    end
  end

  # The LLM lane failed — never block the conversation. Derive a deterministic
  # title from the user's own message and surface the original error.
  defp fallback(user_message, reason) do
    title = fallback_title(user_message)
    Logger.warning("TitleGenerator falling back to \"#{title}\": #{inspect(reason)}")
    {:fallback, title, reason}
  end

  # Title-cased first few words of the user message, or a generic default when
  # the message is empty/blank.
  defp fallback_title(user_message) do
    user_message
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(@max_words)
    |> case do
      [] -> @default_title
      words -> Enum.map_join(words, " ", &capitalize_word/1)
    end
  end

  defp capitalize_word(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
