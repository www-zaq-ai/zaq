defmodule Zaq.Agent.Actions.TranslateKnowledgeQueryFailureTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Actions.TranslateKnowledgeQuery
  alias Zaq.TestSupport.OpenAIStub

  defmodule ProviderErrorGeneration do
    def generate_text(_spec, _messages, _opts), do: {:error, :provider_unavailable}
  end

  defmodule EmptyGeneration do
    alias Zaq.Agent.Actions.TranslateKnowledgeQueryFailureTest.Response

    def generate_text(_spec, _messages, _opts),
      do: Response.response("  \n  ")
  end

  defmodule RaisingGeneration do
    def generate_text(_spec, _messages, _opts), do: raise("generation failed")
  end

  defmodule InvalidJsonGeneration do
    alias Zaq.Agent.Actions.TranslateKnowledgeQueryFailureTest.Response

    def generate_text(_spec, _messages, _opts),
      do: Response.response("{not-json")
  end

  defmodule Response do
    def response(text) do
      {:ok,
       %ReqLLM.Response{
         id: "test-translation",
         model: "test-model",
         context: ReqLLM.Context.new(),
         message: ReqLLM.Context.assistant(text)
       }}
    end
  end

  defp context(generator) do
    %{
      llm_config: OpenAIStub.llm_config("http://example.test/v1") |> Map.new(),
      generation: generator
    }
  end

  test "provider error returns only the simple query and sorted distinct language errors" do
    assert {:ok,
            %{
              queries: %{
                "simple" => %{semantic_query: "red car", lexical_terms: ["red", "car"]}
              },
              errors: ["english", "french"]
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "red car",
                 lexical_terms: [" red ", "car", "red"],
                 languages: ["french", "simple", "english", "french"]
               },
               context(ProviderErrorGeneration)
             )
  end

  test "whitespace-only generation returns no translation and reports the requested language" do
    assert {:ok, response} = EmptyGeneration.generate_text(nil, [], [])
    assert ReqLLM.Response.text(response) == "  \n  "

    assert {:ok, %{queries: %{}, errors: ["french"]}} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{query: "red car", lexical_terms: ["red", "car"], languages: ["french"]},
               context(EmptyGeneration)
             )
  end

  test "generation exception is rescued while retaining the simple query" do
    assert {:ok,
            %{
              queries: %{
                "simple" => %{semantic_query: "red car", lexical_terms: ["red", "car"]}
              },
              errors: ["french"]
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "red car",
                 lexical_terms: ["red", "car"],
                 languages: ["simple", "french"]
               },
               context(RaisingGeneration)
             )
  end

  test "invalid JSON is rejected while retaining the simple query" do
    assert {:ok, response} = InvalidJsonGeneration.generate_text(nil, [], [])
    assert ReqLLM.Response.text(response) == "{not-json"

    assert {:ok,
            %{
              queries: %{
                "simple" => %{semantic_query: "red car", lexical_terms: ["red", "car"]}
              },
              errors: ["french"]
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "red car",
                 lexical_terms: ["red", "car"],
                 languages: ["simple", "french"]
               },
               context(InvalidJsonGeneration)
             )
  end
end
