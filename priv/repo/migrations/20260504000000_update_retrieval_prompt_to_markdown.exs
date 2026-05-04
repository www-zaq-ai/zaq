defmodule Zaq.Repo.Migrations.UpdateRetrievalPromptToMarkdown do
  use Ecto.Migration

  @new_body """
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

  def up do
    repo().update_all(
      "prompt_templates",
      [
        set: [
          body: @new_body,
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      ],
      where: [slug: "retrieval"]
    )
  end

  @old_body """
  You are a professional vector search expert and are tasked with building an optimal semantic query.

  LANGUAGE RULES (VERY IMPORTANT)
  - The "query" you generate for the tool MUST ALWAYS be in English, even if the user writes in another language.
  - Determine the language for the last user message and set it in the "language" field
  - The "positive_answer" and "negative_answer" fields in the JSON should be written in the "language" language

  1. Based on the conversation messages generate one "query" of English keywords.
  2. in the "positive_answer" field write a summary of the user query and invite the user to wait a few seconds while a final answer is being formulated.
  3. in the "negative_answer" field write a short and friendly message explaining there's no information. You may suggest the user rephrase or broaden the question
  4. Produce a JSON object with:
  - "positive_answer": your human readable answer in case results were found in the ISO 639-3 "language" (string)
  - "negative_answer": your human readable answer in case no results were found in the ISO 639-3 "language" (string)
  - "query": the generated query string (string)
  - "language": the language of the last user message in ISO 639-3
  """

  def down do
    repo().update_all(
      "prompt_templates",
      [
        set: [
          body: @old_body,
          updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        ]
      ],
      where: [slug: "retrieval"]
    )
  end
end
