defmodule Zaq.E2E.PlaygroundNodeRouterFake do
  @moduledoc false

  alias Zaq.Agent.{Answering, Retrieval}
  alias Zaq.E2E.DocumentProcessorFake
  alias Zaq.Ingestion.DocumentProcessor

  @prompt_variant_marker "E2E_PROMPT_VARIANT_B"

  def call(:agent, Retrieval, :ask, [question, _opts]) do
    clean_question = question |> to_string() |> String.trim()

    {:ok,
     %{
       "query" => clean_question,
       "language" => "en",
       "positive_answer" => "Searching your knowledge base...",
       "negative_answer" => "No relevant information found in your knowledge base."
     }}
  end

  def call(:ingestion, DocumentProcessor, :query_extraction, [query, role_ids]) do
    DocumentProcessorFake.query_extraction(query, role_ids)
  end

  def call(:agent, Answering, :ask, [system_prompt]) do
    sources = extract_sources(system_prompt)
    source = List.first(sources)
    tuned? = String.contains?(system_prompt, @prompt_variant_marker)

    {body, confidence} =
      if tuned? do
        {"Tuned response generated from the updated prompt template.", 0.96}
      else
        {"Baseline response generated from the default prompt template.", 0.64}
      end

    answer =
      if is_binary(source) do
        "#{body} [source: #{source}]"
      else
        body
      end

    {:ok, %{answer: answer, confidence: %{score: confidence}}}
  end

  def call(_role, mod, fun, args) do
    apply(mod, fun, args)
  end

  def find_node(_supervisor), do: node()

  defp extract_sources(system_prompt) do
    Regex.scan(~r/"source"\s*:\s*"([^"]+)"/, system_prompt, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
