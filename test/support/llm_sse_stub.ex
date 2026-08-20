defmodule Zaq.TestSupport.LLMSSEStub do
  @moduledoc """
  Minimal OpenAI-compatible SSE endpoint for driving a real ReAct run in tests.

  `Zaq.TestSupport.OpenAIStub` answers with plain JSON, which the ReAct runner
  rejects with `{:incomplete_response, :incomplete}` — the runner always streams.
  This stub speaks `text/event-stream` so a full multi-iteration run completes.

  Each request is forwarded to the test process as
  `{:llm_request, turn, decoded_body}`. The first `tool_turns` responses ask for
  the `echo` tool; the next one answers.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)
    :counters.add(opts[:counter], 1, 1)
    turn = :counters.get(opts[:counter], 1)
    send(opts[:test_pid], {:llm_request, turn, Jason.decode!(body)})

    conn =
      conn
      # The stub binds an ephemeral port per test; closing prevents Finch from
      # pooling a connection to a server that is about to be torn down.
      |> put_resp_header("connection", "close")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    Enum.each(chunks(turn, opts[:tool_turns] || 0), fn chunk ->
      {:ok, _} = chunk(conn, "data: #{Jason.encode!(chunk)}\n\n")
    end)

    {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
    conn
  end

  @doc """
  Returns `{child_spec, base_url}` for a stub answering `tool_turns` tool calls
  before its final answer.
  """
  @spec server(non_neg_integer(), pid()) :: {Supervisor.child_spec() | tuple(), String.t()}
  def server(tool_turns, test_pid) do
    port = free_port()

    child_spec =
      {Bandit,
       plug:
         {__MODULE__, test_pid: test_pid, counter: :counters.new(1, []), tool_turns: tool_turns},
       scheme: :http,
       port: port}

    {child_spec, "http://127.0.0.1:#{port}/v1"}
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp chunks(turn, tool_turns) when turn <= tool_turns do
    [
      delta(%{
        role: "assistant",
        tool_calls: [
          %{
            index: 0,
            id: "call_#{turn}",
            type: "function",
            function: %{name: "echo", arguments: ~s({"text":"turn #{turn}"})}
          }
        ]
      }),
      finish("tool_calls")
    ]
  end

  defp chunks(_turn, _tool_turns) do
    [delta(%{role: "assistant", content: "final answer"}), finish("stop")]
  end

  defp delta(delta) do
    %{
      id: "chatcmpl-1",
      object: "chat.completion.chunk",
      created: 1,
      model: "test-model",
      choices: [%{index: 0, delta: delta, finish_reason: nil}]
    }
  end

  defp finish(reason) do
    %{
      id: "chatcmpl-1",
      object: "chat.completion.chunk",
      created: 1,
      model: "test-model",
      choices: [%{index: 0, delta: %{}, finish_reason: reason}]
    }
  end
end
