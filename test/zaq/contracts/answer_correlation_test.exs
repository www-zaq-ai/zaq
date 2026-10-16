defmodule Zaq.Contracts.AnswerCorrelationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.AnswerCorrelation

  @answer "11111111-1111-4111-8111-111111111111"
  @input "22222222-2222-4222-8222-222222222222"

  defp attributes do
    %{
      assistant_message_id: @answer,
      user_message_id: @input,
      request_id: "submission",
      root_request_id: "root"
    }
  end

  test "selected answers carry separate submission, input and root correlation" do
    assert {:ok, correlation} = AnswerCorrelation.new(attributes())
    assert correlation.assistant_message_id == @answer
    assert correlation.user_message_id == @input
    assert correlation.request_id == "submission"
    assert correlation.root_request_id == "root"
  end

  test "a root submission can also be its root request" do
    assert {:ok, _} = AnswerCorrelation.new(%{attributes() | root_request_id: "submission"})
  end

  test "canonical input identity cannot be used as assistant identity" do
    assert {:error, :invalid_answer_correlation} =
             AnswerCorrelation.new(%{attributes() | assistant_message_id: @input})
  end

  test "unselected and malformed bindings are not canonical answer correlations" do
    for key <- Map.keys(attributes()), value <- [nil, "", 7, %{}, self(), <<255>>] do
      assert {:error, :invalid_answer_correlation} =
               AnswerCorrelation.new(Map.put(attributes(), key, value))
    end

    for key <- [:assistant_message_id, :user_message_id] do
      assert {:error, :invalid_answer_correlation} =
               AnswerCorrelation.new(Map.put(attributes(), key, "provider-post"))
    end

    for key <- [:request_id, :root_request_id] do
      assert {:error, :invalid_answer_correlation} =
               AnswerCorrelation.new(Map.put(attributes(), key, String.duplicate("x", 257)))
    end
  end

  test "rejects private fields, edit handles and ambiguous atom/string aliases" do
    for key <- [:finalization_token, :trace, :execution_id, :status_message_id, "unknown"] do
      assert {:error, :invalid_answer_correlation} =
               AnswerCorrelation.new(Map.put(attributes(), key, "private"))
    end

    assert {:error, :invalid_answer_correlation} =
             AnswerCorrelation.new(Map.put(attributes(), "request_id", "different"))

    for value <- [nil, [], "invalid"] do
      assert {:error, :invalid_answer_correlation} = AnswerCorrelation.new(value)
    end
  end

  property "public correlation survives JSON and Erlang transport without allocating identity" do
    check all(request <- string(:alphanumeric, min_length: 1, max_length: 256)) do
      attrs = %{attributes() | request_id: request}
      assert {:ok, correlation} = AnswerCorrelation.new(attrs)
      public = AnswerCorrelation.to_map(correlation)

      assert public == Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)

      assert {:ok, ^correlation} =
               public |> Jason.encode!() |> Jason.decode!() |> AnswerCorrelation.new()

      assert correlation == correlation |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end
end
