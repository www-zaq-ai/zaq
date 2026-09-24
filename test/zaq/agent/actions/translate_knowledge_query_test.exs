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
    stub_llm(~s({"english":"red car","french":"voiture rouge"}))

    assert {:ok, %{translations: %{"english" => "red car", "french" => "voiture rouge"}}} =
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
    stub_llm(~s({"english":"red car"}))

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{details: %{reason: :invalid_translations}}} =
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
end
