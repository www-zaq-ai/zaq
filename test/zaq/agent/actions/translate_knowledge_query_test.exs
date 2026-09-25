defmodule Zaq.Agent.Actions.TranslateKnowledgeQueryTest do
  use Zaq.DataCase, async: false

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
               %{query: "red car", languages: ["french", "english"]},
               %{}
             )

    assert_receive {:openai_request, "POST", "/v1/chat/completions", _, body}
    assert body =~ "red car"
    assert body =~ "french"
  end

  test "missing translations fail explicitly instead of searching untranslated text" do
    stub_llm(~s({"english":{"semantic_query":"red car","lexical_terms":["red","car"]}}))

    assert {:ok, %{queries: %{"english" => _}, errors: ["french"]}} =
             Jido.Exec.run(
               TranslateKnowledgeQuery,
               %{query: "red car", languages: ["english", "french"]},
               %{}
             )
  end

  test "Zoi rejects invalid query and language inputs before requesting an LLM" do
    assert {:error, _} =
             Jido.Exec.run(TranslateKnowledgeQuery, %{query: 9, languages: ["french"]}, %{})

    assert {:error, _} =
             Jido.Exec.run(TranslateKnowledgeQuery, %{query: "cars", languages: [10]}, %{})
  end

  test "separates semantic query from bounded lexical terms and reports invalid languages" do
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
               %{query: "maire 42", languages: ["french", "english"]},
               %{}
             )
  end
end
