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
  def tool_result?(body) do
    body |> tool_results() |> Enum.any?()
  rescue
    ArgumentError -> false
  end

  @doc "Decode a Responses request; reject unsupported input without exposing request contents."
  def decode_request!(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, request} ->
        decode_request!(request)

      _ ->
        raise ArgumentError,
              "Unexpected LLM request: invalid JSON (#{byte_size(body)} bytes; contents omitted)"
    end
  end

  def decode_request!(%{"input" => input} = request) when is_list(input) do
    if Enum.all?(input, &is_map/1) do
      request
    else
      raise ArgumentError,
            "Unexpected LLM request: expected object input items (contents omitted)"
    end
  end

  def decode_request!(_),
    do:
      raise(
        ArgumentError,
        "Unexpected LLM request: expected an object with an input array (contents omitted)"
      )

  @doc "Latest user text, joining input_text parts; image/file parts do not participate in routing."
  def latest_user_message(body) do
    request = decode_request!(body)

    case Enum.find(Enum.reverse(request["input"]), &(&1["role"] == "user")) do
      %{"content" => content} -> user_text(content)
      _ -> raise ArgumentError, "Unexpected LLM request: missing user message (contents omitted)"
    end
  end

  @doc "Ordered tool outputs with call_id, decoded output, and unchanged raw_output."
  def tool_results(body) do
    body
    |> decode_request!()
    |> Map.fetch!("input")
    |> Enum.filter(&(&1["type"] == "function_call_output"))
    |> Enum.map(&tool_output/1)
  end

  defp user_text(content) when is_binary(content) and content != "", do: content

  defp user_text(parts) when is_list(parts) do
    parts
    |> Enum.map_join(fn
      %{"type" => "input_text", "text" => text} when is_binary(text) ->
        text

      %{"type" => type} when type in ["input_image", "input_file"] ->
        ""

      _ ->
        raise ArgumentError,
              "Unexpected LLM request: unsupported user content part (contents omitted)"
    end)
    |> user_text()
  end

  defp user_text(_),
    do: raise(ArgumentError, "Unexpected LLM request: missing user text (contents omitted)")

  defp tool_output(%{"call_id" => id, "output" => output})
       when is_binary(id) and id != "" and (is_binary(output) or is_list(output)) do
    %{call_id: id, output: decode_output(output), raw_output: output}
  end

  defp tool_output(_),
    do:
      raise(
        ArgumentError,
        "Unexpected LLM request: malformed function_call_output (contents omitted)"
      )

  defp decode_output(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, value} -> value
      _ -> output
    end
  end

  defp decode_output(parts) do
    if Enum.all?(parts, &output_part?/1) do
      parts
    else
      raise ArgumentError,
            "Unexpected LLM request: malformed tool output content parts (contents omitted)"
    end
  end

  defp output_part?(%{"type" => "input_text", "text" => text}), do: is_binary(text)
  defp output_part?(%{"type" => "input_image", "image_url" => url}), do: is_binary(url)
  defp output_part?(%{"type" => "input_file", "file_data" => data}), do: is_binary(data)
  defp output_part?(_), do: false
end
