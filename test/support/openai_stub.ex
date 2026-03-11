defmodule Zaq.TestSupport.OpenAIStub do
  @moduledoc false

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    {:ok, body, conn} = read_body(conn)

    send(
      opts[:test_pid],
      {:openai_request, conn.method, conn.request_path, conn.query_string, body}
    )

    case opts[:handler].(conn, body) do
      {status, %{} = response} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(response))

      {status, response} when is_list(response) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(response))

      {status, response} when is_binary(response) ->
        send_resp(conn, status, response)
    end
  end

  def server(handler, test_pid) do
    port = free_port()

    child_spec =
      {Bandit,
       plug: {__MODULE__, test_pid: test_pid, handler: handler}, scheme: :http, port: port}

    {child_spec, "http://127.0.0.1:#{port}/v1"}
  end

  def llm_config(endpoint, overrides \\ []) do
    [
      endpoint: endpoint,
      api_key: "",
      model: "test-model",
      temperature: 0.0,
      top_p: 0.9,
      supports_logprobs: false,
      supports_json_mode: false
    ]
    |> Keyword.merge(overrides)
  end

  def chat_completion(content, opts \\ []) do
    logprobs = Keyword.get(opts, :logprobs)

    usage =
      Keyword.get(opts, :usage, %{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15
      })

    choice = %{
      "index" => 0,
      "message" => %{"role" => "assistant", "content" => content},
      "finish_reason" => "stop"
    }

    choice = if logprobs, do: Map.put(choice, "logprobs", logprobs), else: choice

    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "created" => 0,
      "model" => "test-model",
      "choices" => [choice],
      "usage" => usage
    }
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
