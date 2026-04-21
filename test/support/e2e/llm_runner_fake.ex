defmodule Zaq.E2E.LLMRunnerFake do
  @moduledoc false

  @behaviour Zaq.Agent.LLMRunnerBehaviour

  @prompt_variant_marker "E2E_PROMPT_VARIANT_B"

  @impl true
  def run(opts) when is_list(opts) do
    system_prompt = Keyword.get(opts, :system_prompt, "")
    question = Keyword.get(opts, :question, "")

    content =
      if retrieval_call?(opts) do
        query = question |> to_string() |> String.trim()

        Jason.encode!(%{
          "query" => query,
          "language" => "en",
          "positive_answer" => "Searching your knowledge base...",
          "negative_answer" => "No relevant information found in your knowledge base."
        })
      else
        sources = extract_sources(system_prompt)
        source = List.first(sources)
        tuned? = String.contains?(system_prompt, @prompt_variant_marker)

        body =
          if tuned?,
            do: "Tuned response generated from the updated prompt template.",
            else: "Baseline response generated from the default prompt template."

        if is_binary(source),
          do: "#{body} [[source:#{source}]]",
          else: "#{body} [[memory:llm-general-knowledge]]"
      end

    fake_message = %{content: content, metadata: %{}, status: :complete, role: :assistant}
    {:ok, %{last_message: fake_message, messages: [fake_message], llm: nil}}
  end

  @impl true
  def content_result(%{last_message: %{content: text}}) when is_binary(text) and text != "",
    do: {:ok, text}

  def content_result(_),
    do: {:error, "LLMRunnerFake: no content"}

  # Retrieval passes "Failed to process question"; Answering passes "Failed to formulate response".
  defp retrieval_call?(opts),
    do: String.contains?(Keyword.get(opts, :error_prefix, ""), "process question")

  defp extract_sources(system_prompt) do
    Regex.scan(~r/"source"\s*:\s*"([^"]+)"/, system_prompt, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
