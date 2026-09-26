defmodule Zaq.Agent.Actions.TranslateKnowledgeQueryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Agent.Actions.TranslateKnowledgeQuery
  alias Zaq.TestSupport.OpenAIStub

  defp stub_llm(content) do
    {child_spec, endpoint} =
      OpenAIStub.server(
        fn _conn, _body -> {200, OpenAIStub.chat_completion(content)} end,
        self()
      )

    start_supervised!(child_spec)
    OpenAIStub.seed_llm_config(endpoint)
  end

  test "translates all requested languages with validated output" do
    stub_llm(
      ~s({"english":{"semantic_query":"red car","lexical_terms":["red","car"]},"french":{"semantic_query":"voiture rouge","lexical_terms":["voiture","rouge"]}})
    )

    assert {:ok,
            %{
              queries: %{
                "english" => %{semantic_query: "red car", lexical_terms: ["red", "car"]},
                "french" => %{
                  semantic_query: "voiture rouge",
                  lexical_terms: ["voiture", "rouge"]
                }
              },
              errors: []
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "red car",
                 lexical_terms: ["red", "car"],
                 languages: ["french", "english"]
               },
               %{}
             )

    assert_receive {:openai_request, "POST", "/v1/chat/completions", _, body}
    assert body =~ "red car"
    assert body =~ "french"
    assert body =~ ~s(\\"lexical_terms\\":[\\"red\\",\\"car\\"])
  end

  test "missing translations fail explicitly instead of searching untranslated text" do
    stub_llm(~s({"english":{"semantic_query":"red car","lexical_terms":["red","car"]}}))

    assert {:ok, %{queries: %{"english" => _}, errors: ["french"]}} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "red car",
                 lexical_terms: ["red", "car"],
                 languages: ["english", "french"]
               },
               %{}
             )
  end

  test "Zoi rejects invalid query and language inputs before requesting an LLM" do
    assert {:error, _} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{query: 9, lexical_terms: ["cars"], languages: ["french"]},
               %{}
             )

    assert {:error, _} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{query: "cars", lexical_terms: ["cars"], languages: [10]},
               %{}
             )

    assert {:error, _} =
             Jido.Exec.run(TranslateKnowledgeQuery, %{query: "cars", languages: ["french"]}, %{})
  end

  test "separates semantic query from lexical terms and reports invalid languages" do
    stub_llm(
      ~s({"french":{"semantic_query":"indemnités du maire 42","lexical_terms":["maire","42"]},"english":{"semantic_query":"car","lexical_terms":["", "x"]}})
    )

    assert {:ok,
            %{
              queries: %{
                "french" => %{
                  semantic_query: "indemnités du maire 42",
                  lexical_terms: ["maire", "42"]
                }
              },
              errors: ["english"]
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "maire 42",
                 lexical_terms: ["maire", "42"],
                 languages: ["french", "english"]
               },
               %{}
             )
  end

  test "simple preserves every supplied lexical clause without calling the provider" do
    terms = Enum.map(1..9, &"term#{&1}") ++ ["  Saint-Saturnin  "]

    assert {:ok,
            %{
              queries: %{
                "simple" => %{
                  semantic_query: "Who is mayor of Saint-Saturnin?",
                  lexical_terms: normalized
                }
              },
              errors: []
            }} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{
                 query: "Who is mayor of Saint-Saturnin?",
                 lexical_terms: terms,
                 languages: ["simple"]
               },
               %{}
             )

    assert normalized == Enum.map(1..9, &"term#{&1}") ++ ["Saint-Saturnin"]
  end

  test "translated languages retain more than eight lexical terms and long identifiers" do
    terms = Enum.map(1..9, &"terme#{&1}") ++ ["Saint-Saturnin" <> String.duplicate("q", 130)]
    stub_llm(Jason.encode!(%{"french" => %{semantic_query: "maire", lexical_terms: terms}}))

    assert {:ok, %{queries: %{"french" => %{lexical_terms: ^terms}}, errors: []}} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{query: "mayor", lexical_terms: terms, languages: ["french"]},
               %{}
             )
  end

  property "simple lexical terms keep their first occurrence and do not lose late entries" do
    check all(
            terms <-
              StreamData.uniq_list_of(StreamData.string(:alphanumeric, min_length: 1),
                min_length: 9,
                max_length: 24
              )
          ) do
      assert {:ok, %{queries: %{"simple" => %{lexical_terms: ^terms}}}} =
               Jido.Exec.run(
                 TranslateKnowledgeQuery,
                 %{query: "search", lexical_terms: terms, languages: ["simple"]},
                 %{}
               )
    end
  end
end
