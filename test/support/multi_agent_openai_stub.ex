defmodule Zaq.TestSupport.MultiAgentOpenAIStub do
  @moduledoc false
  # SSE builders for driving a real LLM → tool → LLM loop through `OpenAIStub`.
  #
  # The OpenAI Responses-API streaming shapes here mirror what
  # `ReqLLM.Providers.OpenAI.ResponsesAPI` parses:
  #   - text:       response.output_text.delta → response.completed
  #   - tool call:  response.output_item.added (function_call item) →
  #                 response.function_call_arguments.delta/.done →
  #                 response.output_item.done → response.completed
  #
  # A handler built on these can branch per request on the model and on whether a
  # prior tool result is being fed back (`tool_result?/1`), so one stub serves
  # several agents in a nested run.

  @doc "Final assistant text turn."
  @spec text_sse(String.t(), String.t()) :: binary()
  def text_sse(text, model) do
    delta = Jason.encode!(%{"delta" => text})

    completed =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    """
    event: response.output_text.delta
    data: #{delta}

    event: response.completed
    data: #{completed}

    """
  end

  @doc """
  A single function/tool call turn. `args` is encoded to the JSON-string the
  Responses API delivers as the call arguments.
  """
  @spec tool_call_sse(String.t(), map(), keyword()) :: binary()
  def tool_call_sse(tool_name, args, opts \\ []) do
    model = Keyword.get(opts, :model, "test-model")
    call_id = Keyword.get(opts, :call_id, "call_test_1")
    fc_id = Keyword.get(opts, :fc_id, "fc_test_1")
    args_json = Jason.encode!(args)

    item = %{"type" => "function_call", "call_id" => call_id, "name" => tool_name, "id" => fc_id}

    added = Jason.encode!(%{"item" => item, "output_index" => 0})
    arg_delta = Jason.encode!(%{"delta" => args_json, "output_index" => 0, "call_id" => call_id})

    arg_done =
      Jason.encode!(%{"arguments" => args_json, "output_index" => 0, "call_id" => call_id})

    done = Jason.encode!(%{"item" => Map.put(item, "arguments", args_json), "output_index" => 0})

    completed =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    """
    event: response.output_item.added
    data: #{added}

    event: response.function_call_arguments.delta
    data: #{arg_delta}

    event: response.function_call_arguments.done
    data: #{arg_done}

    event: response.output_item.done
    data: #{done}

    event: response.completed
    data: #{completed}

    """
  end

  @doc "Model string from a Responses-API request body."
  @spec request_model(binary()) :: String.t() | nil
  def request_model(body) do
    case Jason.decode(body) do
      {:ok, %{"model" => model}} -> model
      _ -> nil
    end
  end

  @doc "True once a prior tool result is being fed back (2nd+ LLM turn)."
  @spec tool_result?(binary()) :: boolean()
  def tool_result?(body), do: body =~ "function_call_output"
end
