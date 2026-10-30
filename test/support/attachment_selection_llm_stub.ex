defmodule Zaq.TestSupport.AttachmentSelectionLLMStub do
  @moduledoc "Scripted external model responses for real attachment-selection runtime tests."

  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  def server(script, test_pid) do
    state = ExUnit.Callbacks.start_supervised!({Agent, fn -> {script, 0} end}, id: make_ref())

    handler = fn conn, body ->
      if Jason.decode!(body)["stream"] != true do
        text =
          "**Query:** selected documents\n**Lexical Terms:** [\"selected documents\"]\n**Language:** eng\n**Positive Answer:** Preparing files."

        {200, retrieval_response(conn.request_path, text)}
      else
        {step, index} = Agent.get_and_update(state, &next_step/1)
        request = MultiAgentOpenAIStub.decode_request!(body)

        send(
          test_pid,
          {:attachment_model_request, index, request}
        )

        scripted_response(resolve_step(step, request), index, test_pid)
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, test_pid)
    {Supervisor.child_spec(child, id: make_ref()), endpoint}
  end

  defp next_step({[step | rest], index}), do: {{step, index}, {rest, index + 1}}

  defp resolve_step(step, request) when is_function(step, 1), do: step.(request)
  defp resolve_step(step, _request), do: step

  defp scripted_response({:http_error, status}, _index, _test_pid),
    do: {status, %{error: %{message: "scripted model failure", type: "invalid_request_error"}}}

  defp scripted_response(step, index, test_pid), do: {200, response(step, index, test_pid)}

  defp retrieval_response("/v1/chat/completions", text), do: OpenAIStub.chat_completion(text)

  defp retrieval_response(_path, text) do
    %{
      id: "retrieval_response",
      object: "response",
      model: "gpt-4.1-mini",
      status: "completed",
      output: [
        %{
          id: "retrieval_message",
          type: "message",
          role: "assistant",
          content: [%{type: "output_text", text: text}]
        }
      ],
      usage: %{input_tokens: 5, output_tokens: 5, total_tokens: 10}
    }
  end

  defp response({:pause, next}, index, test_pid) do
    send(test_pid, {:attachment_model_paused, self()})

    receive do
      :release -> response(next, index, test_pid)
    after
      10_000 -> raise "model pause not released"
    end
  end

  defp response({:text, text}, _index, _test_pid),
    do: MultiAgentOpenAIStub.text_sse(text, "gpt-4.1-mini")

  defp response({:call, name, arguments}, index, _test_pid) do
    MultiAgentOpenAIStub.tool_call_sse(name, arguments,
      model: "gpt-4.1-mini",
      call_id: "selection_#{index}",
      fc_id: "fc_selection_#{index}"
    )
  end

  defp response({:tool, operation, records}, index, _test_pid) do
    MultiAgentOpenAIStub.tool_call_sse(
      "attach_documents",
      %{operation: operation, records: records},
      model: "gpt-4.1-mini",
      call_id: "selection_#{index}",
      fc_id: "fc_selection_#{index}"
    )
  end

  defp response({:tools, calls}, index, _test_pid) do
    events =
      calls
      |> Enum.with_index()
      |> Enum.map_join(fn {{op, records}, position} ->
        id = "selection_#{index}_#{position}"

        item = %{
          "type" => "function_call",
          "call_id" => id,
          "name" => "attach_documents",
          "id" => "fc_#{id}"
        }

        args = Jason.encode!(%{operation: op, records: records})

        sse("response.output_item.added", %{item: item, output_index: position}) <>
          sse("response.function_call_arguments.delta", %{
            delta: args,
            output_index: position,
            call_id: id
          }) <>
          sse("response.function_call_arguments.done", %{
            arguments: args,
            output_index: position,
            call_id: id
          }) <>
          sse("response.output_item.done", %{
            item: Map.put(item, "arguments", args),
            output_index: position
          })
      end)

    events <>
      sse("response.completed", %{
        response: %{
          id: "selection_response",
          model: "gpt-4.1-mini",
          usage: %{input_tokens: 5, output_tokens: 1, total_tokens: 6}
        }
      })
  end

  defp sse(event, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
end
