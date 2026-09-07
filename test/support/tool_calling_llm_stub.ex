defmodule Zaq.TestSupport.ToolCallingLLMStub do
  @moduledoc """
  One user-message-selected tool call, followed by one real tool output and a final answer.

  Call `handler/1` or `server/2` from an ExUnit test/setup process. Each handler
  starts its own unnamed, test-supervised Agent; it never runs a tool itself.
  Routes are ordered maps with `:match` (unary predicate), `:tool` (wire name),
  and `:arguments` (unary message-to-map function). The first match wins.

  `:final_response` is a string or unary context callback. Context includes
  `:user_message`, `:tool`, `:arguments`, `:call_id`, `:tool_result`,
  `:raw_output`, and `:raw_request_body`. JSON results retain their decoded
  shape; non-JSON text and content-part arrays remain unchanged.

  Observations go to `:test_pid` (default: caller):
  `{:llm_tool_call, tool, string_keyed_arguments}` and
  `{:llm_tool_result, tool, decoded_result}`. Call observations describe the
  stub's emitted call; the correlated result is evidence of actual execution.
  Protocol errors send `{:llm_stub_error, message}` and raise in the HTTP caller.
  A failed or finished handler cannot start another interaction. By default,
  each instance handles one interaction. Set `:max_interactions` to a positive
  integer for sequential messages on the same live agent: each message still
  makes exactly one tool call, and previously observed input must be retained
  unchanged. Multi-tool asks and rewritten/truncated histories belong in
  MultiAgentOpenAIStub. Raw observations always contain the full HTTP body.
  """

  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  @doc "Build a handler compatible with OpenAIStub.server/2; must be called inside ExUnit."
  def handler(opts) do
    routes = Keyword.fetch!(opts, :routes)
    final_response = Keyword.fetch!(opts, :final_response)
    test_pid = Keyword.get(opts, :test_pid, self())
    limit = Keyword.get(opts, :max_interactions, 1)
    expect!(is_integer(limit) and limit > 0, "max_interactions must be a positive integer")

    state =
      ExUnit.Callbacks.start_supervised!({Agent, fn -> {:initial, limit, []} end}, id: make_ref())

    fn conn, body ->
      result =
        Agent.get_and_update(state, &advance(&1, conn, body, routes, final_response, test_pid))

      case result do
        {:ok, sse} ->
          {200, sse}

        {:error, message} ->
          send(test_pid, {:llm_stub_error, message})
          raise ArgumentError, message
      end
    end
  end

  @doc "Return an OpenAIStub child spec and endpoint; start the child with start_supervised!/1."
  def server(routes, opts) do
    test_pid = Keyword.get(opts, :test_pid, self())
    handler = handler(Keyword.put(opts, :routes, routes))
    {child, endpoint} = OpenAIStub.server(handler, test_pid)
    {Supervisor.child_spec(child, id: make_ref()), endpoint}
  end

  defp advance(state, conn, body, routes, final_response, test_pid) do
    validate_http!(conn)
    request = MultiAgentOpenAIStub.decode_request!(body)
    {sse, next_state} = respond(state, request, body, routes, final_response, test_pid)
    {{:ok, sse}, next_state}
  rescue
    error in ArgumentError ->
      {{:error, Exception.message(error) <> request_summary(body)}, :failed}

    error ->
      {{:error,
        "Unexpected LLM request: callback or configuration failed (#{inspect(error.__struct__)}; contents omitted)"},
       :failed}
  end

  defp respond(
         {:initial, remaining, history},
         full_request,
         _body,
         routes,
         _final_response,
         test_pid
       ) do
    request = initial_turn!(full_request, history)

    expect!(
      MultiAgentOpenAIStub.tool_results(request) == [],
      "expected initial user turn without tool outputs"
    )

    expect!(
      Enum.all?(request["input"], &(&1["type"] != "function_call")),
      "expected initial user turn without prior function calls"
    )

    message = MultiAgentOpenAIStub.latest_user_message(request)
    route = Enum.find(routes, &callback!(&1.match, message))

    expect!(
      route != nil,
      "no route matched latest user text (#{length(routes)} configured routes)"
    )

    expect!(advertised?(request, route.tool), "selected tool not advertised in request")
    arguments = callback!(route.arguments, message)
    expect!(is_map(arguments), "route arguments must be a map")
    arguments = arguments |> Jason.encode!() |> Jason.decode!()
    call_id = "call_#{System.unique_integer([:positive, :monotonic])}"

    context = %{
      user_message: message,
      tool: route.tool,
      arguments: arguments,
      call_id: call_id,
      remaining: remaining,
      request_input: full_request["input"]
    }

    sse =
      MultiAgentOpenAIStub.tool_call_sse(route.tool, arguments,
        model: model!(request),
        call_id: call_id,
        fc_id: "fc_#{call_id}"
      )

    send(test_pid, {:llm_tool_call, route.tool, arguments})
    {sse, {:awaiting_result, context}}
  end

  defp respond({:awaiting_result, context}, full_request, body, _routes, final_response, test_pid) do
    suffix = appended_input!(full_request, context.request_input)

    expect!(
      match?([%{"type" => "function_call"}, %{"type" => "function_call_output"}], suffix),
      "expected only the pending function call and its output"
    )

    request = Map.put(full_request, "input", [List.last(context.request_input) | suffix])
    results = MultiAgentOpenAIStub.tool_results(request)
    expect!(length(results) == 1, "expected exactly one pending tool result")
    [result] = results
    expect!(result.call_id == context.call_id, "tool result call_id does not match pending call")

    expect!(
      MultiAgentOpenAIStub.latest_user_message(request) == context.user_message,
      "user message changed during tool continuation"
    )

    verify_call!(request, context)

    context =
      Map.merge(context, %{
        tool_result: result.output,
        raw_output: result.raw_output,
        raw_request_body: body
      })

    send(test_pid, {:llm_tool_result, context.tool, result.output})

    text =
      if is_function(final_response, 1),
        do: callback!(final_response, context),
        else: final_response

    expect!(is_binary(text), "final_response must return text")

    next_state =
      if context.remaining == 1,
        do: :finished,
        else: {:initial, context.remaining - 1, %{input: full_request["input"], final_text: text}}

    {MultiAgentOpenAIStub.text_sse(text, model!(request)), next_state}
  end

  defp respond(state, _request, _body, _routes, _final_response, _test_pid),
    do:
      raise(
        ArgumentError,
        "Unexpected LLM request: interaction already #{state} (contents omitted)"
      )

  defp initial_turn!(request, []), do: request

  defp initial_turn!(request, %{input: history, final_text: text}) do
    suffix = appended_input!(request, history)

    expect!(
      match?([%{"role" => "assistant"}, %{"role" => "user"}], suffix),
      "expected the final assistant answer followed by one new user message"
    )

    [assistant, user] = suffix

    expect!(
      assistant["content"] == [%{"type" => "output_text", "text" => text}] and
        is_nil(assistant["type"]),
      "previous final assistant answer changed"
    )

    Map.put(request, "input", [user])
  end

  defp appended_input!(request, history) do
    {prefix, suffix} = Enum.split(request["input"], length(history))
    expect!(prefix == history, "previously observed input history changed")
    suffix
  end

  defp verify_call!(request, context) do
    calls = Enum.filter(request["input"], &(&1["type"] == "function_call"))
    expect!(length(calls) == 1, "expected one echoed function call")
    [call] = calls

    expect!(
      match?([^call, %{"type" => "function_call_output"}], Enum.take(request["input"], -2)),
      "expected echoed call followed by its output at end of input"
    )

    expect!(
      call["call_id"] == context.call_id and call["name"] == context.tool,
      "echoed call identity differs from emitted call"
    )

    expect!(
      decode_arguments(call["arguments"]) == context.arguments,
      "echoed arguments differ from emitted call"
    )
  end

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_arguments(_), do: nil

  defp advertised?(%{"tools" => tools}, name) when is_list(tools),
    do: Enum.any?(tools, &match?(%{"type" => "function", "name" => ^name}, &1))

  defp advertised?(_, _), do: false

  defp model!(%{"model" => model}) when is_binary(model) and model != "", do: model

  defp model!(_),
    do: raise(ArgumentError, "Unexpected LLM request: missing model (contents omitted)")

  defp expect!(true, _reason), do: :ok

  defp expect!(false, reason),
    do: raise(ArgumentError, "Unexpected LLM request: #{reason} (contents omitted)")

  defp callback!(callback, input) do
    callback.(input)
  rescue
    error ->
      reraise ArgumentError.exception(
                "Unexpected LLM request: callback raised #{inspect(error.__struct__)} (contents omitted)"
              ),
              __STACKTRACE__
  catch
    kind, _reason ->
      raise ArgumentError, "Unexpected LLM request: callback #{kind} (contents omitted)"
  end

  # nil is reserved for focused handler tests without an HTTP connection.
  defp validate_http!(nil), do: :ok
  defp validate_http!(%Plug.Conn{method: "POST", request_path: "/v1/responses"}), do: :ok
  defp validate_http!(_), do: expect!(false, "expected POST /v1/responses")

  # Report only structural metadata: prompts, outputs, and arbitrary JSON keys
  # can contain credentials or private data, including in callback exceptions.
  defp request_summary(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"input" => input}} when is_list(input) ->
        " Received: #{byte_size(body)} bytes, #{length(input)} input items."

      _ ->
        " Received: #{byte_size(body)} bytes."
    end
  end

  defp request_summary(_), do: " Received: non-binary request."
end
