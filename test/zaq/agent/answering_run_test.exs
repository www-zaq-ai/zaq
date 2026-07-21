defmodule Zaq.Agent.AnsweringRunTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.AnsweringRun

  test "uses only the authoritative request result" do
    intermediate = %{
      kind: :llm_delta,
      iteration: 1,
      llm_call_id: "tool-selection",
      data: %{chunk_type: :content, delta: "intermediate"}
    }

    completed = %{
      kind: :request_completed,
      data: %{result: "Final answer [[source:documents/report.pdf|p2]]."}
    }

    assert AnsweringRun.classify_event(intermediate) == :ignore
    assert AnsweringRun.classify_event(completed) == {:done, "Final answer."}
  end

  test "extracts retrieval chunks from tool results" do
    chunks = [%{"document_id" => 1, "page" => 2, "source" => "documents/report.pdf"}]

    event = %{
      kind: :tool_completed,
      data: %{result: {:ok, %{chunks: chunks}, []}}
    }

    assert AnsweringRun.extract_chunks(event) == chunks
  end

  test "normalizes whitespace left by inline source markers" do
    answer =
      "First claim [[source:documents/a.pdf|p1]].  \nSecond claim [[source:documents/a.pdf|p2]]."

    assert AnsweringRun.clean_answer(answer) ==
             """
             First claim.
             Second claim.
             """
             |> String.trim()
  end
end
