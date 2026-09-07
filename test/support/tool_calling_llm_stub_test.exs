defmodule Zaq.TestSupport.ToolCallingLLMStubTest do
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.ToolCallingLLMStub, as: Stub

  test "message selects either route and observable arguments match emitted SSE" do
    for {message, tool, value} <- [{"add", "add", 2}, {"subtract", "subtract", 10}] do
      handler =
        Stub.handler(
          routes: routes(),
          final_response: fn ctx -> "RESULT=#{Jason.encode!(ctx.tool_result)}" end
        )

      body = initial(message)
      {200, sse} = handler.(nil, body)
      call = emitted_call(sse)
      assert call["name"] == tool
      assert Jason.decode!(call["arguments"]) == %{"value" => value, "amount" => 3}
      assert_received {:llm_tool_call, ^tool, %{"value" => ^value, "amount" => 3}}

      {200, final} = handler.(nil, continuation(body, call, ~s({"result":5})))
      assert_received {:llm_tool_result, ^tool, %{"result" => 5}}
      assert final =~ "RESULT="
      assert final =~ "response.completed"
      assert_raise ArgumentError, ~r/finished/, fn -> handler.(nil, body) end
      assert_received {:llm_stub_error, _}
    end
  end

  test "fixed response, raw context and independent instances" do
    test_pid = self()

    first =
      Stub.handler(
        routes: routes(),
        final_response: fn ctx ->
          send(test_pid, {:context, ctx})
          "done"
        end
      )

    second = Stub.handler(routes: routes(), final_response: "fixed")
    body = initial("add")
    {200, sse1} = first.(nil, body)
    {200, sse2} = second.(nil, body)
    call1 = emitted_call(sse1)
    call2 = emitted_call(sse2)
    refute call1["call_id"] == call2["call_id"]
    raw = continuation(body, call1, "plain result")
    assert {200, _} = first.(nil, raw)

    assert_received {:context,
                     %{
                       tool_result: "plain result",
                       raw_output: "plain result",
                       raw_request_body: ^raw,
                       user_message: "add"
                     }}

    {200, final} = second.(nil, continuation(body, call2, "null"))
    assert final =~ "fixed"
    assert_received {:llm_tool_result, "add", nil}
  end

  test "fails loudly on no match, unsupported shape and unadvertised tools" do
    for {body, reason} <- [
          {initial("unknown secret"), "no route matched"},
          {"not-json-secret", "invalid JSON"},
          {initial("add", []), "not advertised"}
        ] do
      handler = Stub.handler(routes: routes(), final_response: "done")
      error = assert_raise ArgumentError, fn -> handler.(nil, body) end
      assert error.message =~ reason
      refute error.message =~ "secret"
      assert byte_size(error.message) < 1000
      assert_received {:llm_stub_error, _}
    end
  end

  test "rejects missing, duplicate, foreign and altered result calls" do
    for variant <- [:missing, :duplicate, :foreign, :altered] do
      handler = Stub.handler(routes: routes(), final_response: "done")
      body = initial("add")
      {200, sse} = handler.(nil, body)
      call = emitted_call(sse)
      request = Jason.decode!(continuation(body, call, "5"))
      input = request["input"]

      bad_input =
        case variant do
          :missing -> Jason.decode!(body)["input"]
          :duplicate -> input ++ [List.last(input)]
          :foreign -> List.update_at(input, -1, &Map.put(&1, "call_id", "foreign"))
          :altered -> List.update_at(input, -2, &Map.put(&1, "arguments", "{}"))
        end

      assert_raise ArgumentError, ~r/Unexpected LLM request/, fn ->
        handler.(nil, Jason.encode!(%{request | "input" => bad_input}))
      end

      assert_raise ArgumentError, ~r/failed/, fn ->
        handler.(nil, continuation(body, call, "5"))
      end
    end
  end

  test "rejects an unsolicited result on the initial turn" do
    handler = Stub.handler(routes: routes(), final_response: "done")

    body =
      continuation(
        initial("add"),
        %{"call_id" => "old", "name" => "add", "type" => "function_call", "arguments" => "{}"},
        "5"
      )

    assert_raise ArgumentError, ~r/initial/, fn -> handler.(nil, body) end
  end

  test "server uses the real HTTP boundary and returns its final SSE" do
    {child, endpoint} = Stub.server(routes(), final_response: "done")
    start_supervised!(child)
    body = initial("subtract")
    response = Req.post!(endpoint <> "/responses", body: body)
    call = emitted_call(response.body)
    assert call["name"] == "subtract"

    response =
      Req.post!(endpoint <> "/responses", body: continuation(body, call, ~s({"result":7})))

    assert response.body =~ "done"
    assert_received {:llm_tool_result, "subtract", %{"result" => 7}}
  end

  test "arguments derive from user text and the first matching route wins" do
    route = %{
      match: fn _ -> true end,
      tool: "add",
      arguments: fn message -> %{value: String.to_integer(message), amount: 3} end
    }

    handler = Stub.handler(routes: [route | routes()], final_response: "done", test_pid: self())
    {200, sse} = handler.(nil, initial("42"))
    assert Jason.decode!(emitted_call(sse)["arguments"]) == %{"value" => 42, "amount" => 3}
    assert_received {:llm_tool_call, "add", %{"value" => 42, "amount" => 3}}
  end

  test "concurrent duplicate first turns cannot both emit calls" do
    handler = Stub.handler(routes: routes(), final_response: "done")

    results =
      1..2
      |> Task.async_stream(fn _ ->
        try do
          handler.(nil, initial("add"))
        rescue
          ArgumentError -> :rejected
        end
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({200, _}, &1)) == 1
    assert :rejected in results
    assert_received {:llm_tool_call, "add", _}
    refute_received {:llm_tool_call, _, _}
  end

  test "callback errors are sanitized and invalid callback values fail" do
    base = hd(routes())

    for route <- [
          %{base | match: fn _ -> raise ArgumentError, "private-secret" end},
          %{base | arguments: fn _ -> raise "private-secret" end},
          %{base | arguments: fn _ -> [] end},
          Map.delete(base, :arguments)
        ] do
      handler = Stub.handler(routes: [route], final_response: "done")
      error = assert_raise ArgumentError, fn -> handler.(nil, initial("add")) end
      refute error.message =~ "private-secret"
    end

    for final <- [fn _ -> raise ArgumentError, "private-secret" end, fn _ -> nil end] do
      handler = Stub.handler(routes: routes(), final_response: final)
      body = initial("add")
      {200, sse} = handler.(nil, body)

      error =
        assert_raise ArgumentError, fn ->
          handler.(nil, continuation(body, emitted_call(sse), "5"))
        end

      refute error.message =~ "private-secret"
    end
  end

  test "callback throws and exits poison the interaction without killing state" do
    for callback <- [fn _ -> throw("private-secret") end, fn _ -> exit("private-secret") end],
        stage <- [:match, :final] do
      route = if stage == :match, do: %{hd(routes()) | match: callback}, else: hd(routes())
      final = if stage == :final, do: callback, else: "done"
      handler = Stub.handler(routes: [route], final_response: final)
      body = initial("add")

      body =
        if stage == :final do
          {200, sse} = handler.(nil, body)
          continuation(body, emitted_call(sse), "5")
        else
          body
        end

      error = assert_raise ArgumentError, ~r/callback/, fn -> handler.(nil, body) end
      refute error.message =~ "private-secret"
      assert_received {:llm_stub_error, _}
      assert_raise ArgumentError, ~r/already failed/, fn -> handler.(nil, body) end
    end
  end

  test "rejects requests to a wrong method or endpoint" do
    for conn <- [
          Plug.Test.conn(:get, "/v1/responses"),
          Plug.Test.conn(:post, "/v1/chat/completions")
        ] do
      handler = Stub.handler(routes: routes(), final_response: "done")
      assert_raise ArgumentError, ~r/expected POST/, fn -> handler.(conn, initial("add")) end
      assert_received {:llm_stub_error, _}
    end
  end

  test "rejects missing model/tools and non-binary requests without leaking contents" do
    request = Jason.decode!(initial("add"))

    for body <- [
          Jason.encode!(Map.delete(request, "model")),
          Jason.encode!(Map.delete(request, "tools")),
          nil
        ] do
      handler = Stub.handler(routes: routes(), final_response: "done")
      assert_raise ArgumentError, ~r/Unexpected LLM request/, fn -> handler.(nil, body) end
    end
  end

  test "rejects changed messages, missing or reordered calls and malformed echoed arguments" do
    for variant <- [
          :message,
          :missing_call,
          :reordered,
          :name,
          :call_id,
          :bad_json,
          :missing_arguments
        ] do
      handler = Stub.handler(routes: routes(), final_response: "done")
      body = initial("add")
      {200, sse} = handler.(nil, body)
      call = emitted_call(sse)
      request = Jason.decode!(continuation(body, call, "5"))
      [user, echoed, output] = request["input"]

      input =
        case variant do
          :message -> [Map.put(user, "content", "changed"), echoed, output]
          :missing_call -> [user, output]
          :reordered -> [user, output, echoed]
          :name -> [user, Map.put(echoed, "name", "foreign"), output]
          :call_id -> [user, Map.put(echoed, "call_id", "foreign"), output]
          :bad_json -> [user, Map.put(echoed, "arguments", "invalid"), output]
          :missing_arguments -> [user, Map.delete(echoed, "arguments"), output]
        end

      assert_raise ArgumentError, fn ->
        handler.(nil, Jason.encode!(%{request | "input" => input}))
      end
    end
  end

  defp routes do
    for {tool, value} <- [{"add", 2}, {"subtract", 10}] do
      %{match: &(&1 == tool), tool: tool, arguments: fn _ -> %{value: value, amount: 3} end}
    end
  end

  defp initial(
         message,
         tools \\ [
           %{"type" => "function", "name" => "add"},
           %{"type" => "function", "name" => "subtract"}
         ]
       ) do
    Jason.encode!(%{
      "model" => "test-model",
      "tools" => tools,
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => message}]}
      ]
    })
  end

  defp continuation(body, call, output) do
    request = Jason.decode!(body)
    result = %{"type" => "function_call_output", "call_id" => call["call_id"], "output" => output}
    Jason.encode!(%{request | "input" => request["input"] ++ [call, result]})
  end

  defp emitted_call(sse) do
    sse
    |> String.split("\n\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, "event: response.output_item.done\n"))
    |> String.split("data: ", parts: 2)
    |> List.last()
    |> Jason.decode!()
    |> Map.fetch!("item")
  end
end
