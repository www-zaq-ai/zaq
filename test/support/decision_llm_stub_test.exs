defmodule Zaq.TestSupport.DecisionLLMStubTest do
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.OpenAIStub

  test "scripts decision responses at the existing HTTP boundary without inferring answers" do
    answers = %{
      "team" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.9, "support" => 0.1}
      },
      "urgency" => %{"type" => "score", "score" => 0.2},
      "refund" => %{"type" => "noul", "noul" => 0.95}
    }

    response = OpenAIStub.decision_response(answers, model: "typesafe/jev-1.14")

    {_pid, endpoint} =
      OpenAIStub.start!(
        fn conn, body ->
          assert conn.method == "POST"
          assert conn.request_path == "/v1/systemone"
          assert Jason.decode!(body) == %{"state" => "An unrelated input"}
          {200, response}
        end,
        self()
      )

    assert {:ok, %{status: 200, body: body}} =
             Req.post(endpoint <> "/systemone", json: %{state: "An unrelated input"})

    assert body["answers"] == answers
    assert body["model"] == "typesafe/jev-1.14"
    assert body["usage"] == %{"input_tokens" => 10, "output_tokens" => 5}
    assert_receive {:openai_request, "POST", "/v1/systemone", "", _}
  end

  test "preserves provider answer lists, absent distributions and explicit usage" do
    answers = [%{"name" => "team", "type" => "refusal"}]

    assert %{"answers" => ^answers, "usage" => %{"input_tokens" => 3}} =
             OpenAIStub.decision_response(answers, usage: %{"input_tokens" => 3})
  end
end
