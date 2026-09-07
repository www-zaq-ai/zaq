defmodule Zaq.TestSupport.MultiAgentOpenAIStubTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.TestSupport.MultiAgentOpenAIStub, as: Stub

  test "extracts latest user text, not system or assistant content" do
    body = %{
      "model" => "test-model",
      "input" => [
        %{"role" => "user", "content" => "old"},
        %{"role" => "system", "content" => "ignore"},
        %{
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "add "},
            %{"type" => "input_image", "image_url" => "redacted"},
            %{"type" => "input_text", "text" => "2 and 3"}
          ]
        },
        %{"role" => "assistant", "content" => "ignore"}
      ]
    }

    assert Stub.latest_user_message(Jason.encode!(body)) == "add 2 and 3"
    assert Stub.request_model(Jason.encode!(body)) == "test-model"

    assert Stub.latest_user_message(%{"input" => [%{"role" => "user", "content" => "hello"}]}) ==
             "hello"
  end

  test "detects typed results and preserves non-JSON outputs" do
    refute Stub.tool_result?(
             Jason.encode!(%{
               "input" => [%{"role" => "user", "content" => "function_call_output"}]
             })
           )

    refute Stub.tool_result?("invalid")
    refute Stub.tool_result?("{}")
    assert Stub.request_model("invalid") == nil

    parts = [
      %{"type" => "input_text", "text" => "result"},
      %{"type" => "input_image", "image_url" => "data:image/png;base64,AA=="},
      %{"type" => "input_file", "file_data" => "data:application/pdf;base64,AA=="}
    ]

    for output <- ["plain text", parts] do
      body = request(output)
      assert Stub.tool_result?(body)
      assert Stub.tool_results(body) == [%{call_id: "call_1", output: output, raw_output: output}]
    end
  end

  property "JSON output normalization preserves values without atomizing keys" do
    check all(
            value <-
              one_of([
                integer(),
                boolean(),
                string(:alphanumeric),
                list_of(integer(), max_length: 5)
              ])
          ) do
      result = %{"result" => value}
      raw = Jason.encode!(result)

      assert Stub.tool_results(request(raw)) == [
               %{call_id: "call_1", output: result, raw_output: raw}
             ]
    end
  end

  test "rejects malformed requests, missing text and malformed result items" do
    for output <- [[123], [nil], [%{}], [%{"type" => "input_text", "text" => nil}]] do
      assert_raise ArgumentError, ~r/content parts/, fn -> Stub.tool_results(request(output)) end
    end

    for body <- ["secret-invalid-json", "[]", "{}", %{"input" => "bad"}, %{"input" => [42]}] do
      assert_raise ArgumentError, ~r/Unexpected LLM request/, fn -> Stub.decode_request!(body) end
    end

    for input <- [
          [],
          [%{"role" => "user", "content" => nil}],
          [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => 1}]}],
          [%{"role" => "user", "content" => [%{"type" => "input_image"}]}]
        ] do
      assert_raise ArgumentError, fn -> Stub.latest_user_message(%{"input" => input}) end
    end

    for item <- [
          %{"type" => "function_call_output"},
          %{"type" => "function_call_output", "call_id" => "x", "output" => 123}
        ] do
      assert_raise ArgumentError, fn -> Stub.tool_results(%{"input" => [item]}) end
    end
  end

  defp request(output) do
    Jason.encode!(%{
      "input" => [%{"type" => "function_call_output", "call_id" => "call_1", "output" => output}]
    })
  end
end
