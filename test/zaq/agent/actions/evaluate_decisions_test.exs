defmodule Zaq.Agent.Actions.EvaluateDecisionsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.Action.Error, as: ActionError
  alias Zaq.Agent.Actions.EvaluateDecisions
  alias Zaq.System
  alias Zaq.TestSupport.OpenAIStub

  @questions %{
    "team" => %{
      "type" => "choice",
      "instructions" => "Which team?",
      "criteria" => %{"billing" => "Payments", "support" => "Technical problems"}
    },
    "refund" => %{"type" => "boolean", "instructions" => "Is a refund requested?"},
    "urgency" => %{
      "type" => "score",
      "instructions" => "Assess urgency",
      "criteria" => ["Routine", "Critical"]
    }
  }
  @answers %{
    "team" => %{
      "type" => "choice",
      "choice" => "billing",
      "confidence" => 0.8,
      "probabilities" => %{"billing" => 0.9, "support" => 0.1}
    },
    "refund" => %{"type" => "noul", "noul" => 0.5},
    "urgency" => %{"type" => "score", "score" => 0.25}
  }

  test "batches three typed questions with real provider encoding and JSON-safe output" do
    configure(@answers)
    params = %{"state" => %{"ticket" => "Refund me"}, "questions" => @questions}
    assert {:ok, %{decisions: decisions}} = Jido.Exec.run(EvaluateDecisions, params, %{})

    assert decisions == %{
             "team" => %{
               "type" => "choice",
               "value" => "billing",
               "confidence" => 0.8,
               "probabilities" => %{"billing" => 0.9, "support" => 0.1}
             },
             "refund" => %{
               "type" => "boolean",
               "value" => true,
               "probability" => 0.5,
               "threshold" => 0.5
             },
             "urgency" => %{
               "type" => "score",
               "value" => 0.25,
               "confidence" => nil,
               "probabilities" => nil
             }
           }

    assert Jason.decode!(Jason.encode!(decisions)) == decisions
    assert_receive {:openai_request, "POST", "/v1/systemone", "", body}
    request = Jason.decode!(body)
    assert request["state"] == %{"ticket" => "Refund me"}
    assert request["questions"]["refund"]["type"] == "noul"
    refute Map.has_key?(request["questions"]["refund"], "threshold")
    refute Map.has_key?(request, "temperature")
    refute_receive {:openai_request, _, _, _, _}
  end

  test "normalizes list distributions and preserves partial maps without inventing confidence" do
    answers =
      @answers
      |> put_in(["team", "probabilities"], [%{"value" => "support", "probability" => 0.0}])
      |> put_in(["urgency", "probabilities"], [
        %{"value" => 0, "probability" => 0.75},
        %{"value" => 1, "probability" => 0.25}
      ])

    configure(answers)
    assert {:ok, %{decisions: result}} = execute()
    assert result["team"]["value"] == "billing"
    assert result["team"]["probabilities"] == %{"support" => 0.0}
    assert result["urgency"]["probabilities"] == %{"0" => 0.75, "1" => 0.25}
    assert result["urgency"]["confidence"] == nil
  end

  test "invalid response contracts fail the whole invocation without leaking provider content" do
    for answers <- [
          Map.delete(@answers, "team"),
          Map.put(@answers, "extra", %{"type" => "boolean", "probability" => 1}),
          put_in(@answers, ["team", "choice"], "PRIVATE_UNKNOWN_CHOICE"),
          put_in(@answers, ["team", "probabilities"], %{"billing" => 1.1}),
          put_in(@answers, ["team", "probabilities"], [
            %{"value" => "billing", "probability" => 0.5},
            %{"value" => "billing", "probability" => 0.5}
          ]),
          put_in(@answers, ["urgency", "score"], 2),
          put_in(@answers, ["refund", "noul"], -1)
        ] do
      configure(answers)
      assert {:error, error} = execute()
      assert Exception.message(error) =~ "decision_response_invalid"
      refute Exception.message(error) =~ "PRIVATE"
    end
  end

  test "refusals and HTTP failures have bounded errors, not success-shaped partial output" do
    configure(Map.put(@answers, "team", %{"type" => "refusal", "reason" => "PRIVATE"}))
    assert {:error, error} = execute()
    assert Exception.message(error) =~ "decision_refused"

    configure(%{"error" => "PRIVATE"}, 401)
    assert {:error, error} = execute()
    assert Exception.message(error) =~ "decision_authentication_failed"
    refute Exception.message(error) =~ "PRIVATE"
  end

  test "invalid inputs fail before HTTP and explicit deadlines do not start inference" do
    configure(@answers)

    for questions <- [
          %{},
          put_in(@questions, ["refund", "threshold"], 1.1),
          put_in(@questions, ["team", "criteria"], %{"only" => "one"}),
          put_in(@questions, ["urgency", "criteria"], ["duplicate", "duplicate"]),
          put_in(@questions, ["team", "threshold"], 0.5),
          put_in(@questions, ["refund", "unexpected"], "ignored?")
        ] do
      assert {:error, _} =
               Jido.Exec.run(EvaluateDecisions, %{state: "text", questions: questions}, %{})
    end

    assert {:error, _} =
             Jido.Exec.run(EvaluateDecisions, %{state: self(), questions: @questions}, %{})

    assert {:error, _} =
             Jido.Exec.run(
               EvaluateDecisions,
               %{state: "text", questions: @questions},
               %{decision_deadline: Elixir.System.monotonic_time(:millisecond) - 1}
             )

    refute_receive {:openai_request, _, _, _, _}
  end

  test "non-map inputs pass through the pre-validation callback but remain invalid" do
    input = ["not", "decision params"]

    assert {:ok, ^input} = EvaluateDecisions.on_before_validate_params(input)
    assert {:error, _} = Jido.Exec.run(EvaluateDecisions, input, %{})
  end

  test "configured evaluation sanitizes exceptions raised by malformed trusted context" do
    configure(@answers)

    assert {:error, error} =
             Jido.Exec.run(
               EvaluateDecisions,
               %{state: "Refund me", questions: @questions},
               %{decision_deadline: "PRIVATE_DEADLINE_SENTINEL"}
             )

    assert Exception.message(error) == "decision_model_unsupported"
    refute Exception.message(error) =~ "PRIVATE_DEADLINE_SENTINEL"
    refute ActionError.retryable?(error)
    refute_receive {:openai_request, _, _, _, _}
  end

  test "unconfigured and unsupported selections fail without chat fallback" do
    assert {:error, error} = execute()
    assert Exception.message(error) =~ "decision_model_not_configured"

    System.set_config("global.decision_model.model", "partial")
    assert {:error, error} = execute()
    assert Exception.message(error) =~ "decision_model_not_configured"

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "custom",
        endpoint: "http://127.0.0.1:1",
        api_key: "test-key"
      })

    assert {:ok, _} =
             System.save_decision_model_config(%{credential_id: credential.id, model: "unlisted"})

    assert {:error, error} = execute()
    assert Exception.message(error) =~ "decision_model_unsupported"
  end

  test "HTTP errors do not trigger hidden Action or HTTP retries" do
    for status <- [429, 503] do
      configure(%{"error" => "PRIVATE"}, status)
      assert {:error, error} = execute()
      assert Exception.message(error) == "decision_request_failed"
      refute ActionError.retryable?(error)
      assert_receive {:openai_request, "POST", "/v1/systemone", _, _}
      refute_receive {:openai_request, _, _, _, _}
    end
  end

  property "native question fields and arbitrary string IDs survive without atom creation" do
    check all(id <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      questions = %{id => %{type: :boolean, instructions: "Decide"}}
      params = %{state: %{"safe" => [true, false, nil, 0]}, questions: questions}
      assert {:ok, normalized} = EvaluateDecisions.on_before_validate_params(params)
      assert {:ok, valid} = EvaluateDecisions.validate_params(normalized)
      assert valid.questions[id]["type"] == "boolean"
    end
  end

  test "rejects atom/string collisions rather than silently dropping either input" do
    assert {:error, _} =
             EvaluateDecisions.on_before_validate_params(%{
               :state => "a",
               "state" => "b",
               :questions => @questions
             })
  end

  defp execute do
    Jido.Exec.run(EvaluateDecisions, %{state: "Refund me", questions: @questions}, %{})
  end

  defp configure(answers, status \\ 200) do
    {server, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert conn.method == "POST"
          assert conn.request_path == "/v1/systemone"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer decision-test-key"]
          assert Jason.decode!(body)["model"] == "typesafe/jev-1.14"
          {status, OpenAIStub.decision_response(answers)}
        end,
        self()
      )

    start_supervised!(server, id: make_ref())

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "zaq_router",
        endpoint: endpoint,
        api_key: "decision-test-key"
      })

    assert {:ok, _} =
             System.save_decision_model_config(%{
               credential_id: credential.id,
               model: "typesafe/jev-1.14"
             })
  end
end
