defmodule ZaqWeb.E2EController do
  @moduledoc false

  use ZaqWeb, :controller

  alias Zaq.E2E.{LogCollector, ProcessorState, Reset}
  alias Zaq.Engine.Telemetry

  @e2e_enabled Application.compile_env(:zaq, :e2e, false)

  # Final safety net — routes compile away in prod, but this guards at action level too.
  def action(conn, _) do
    if @e2e_enabled do
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    else
      conn |> put_status(:not_found) |> json(%{error: "not found"}) |> halt()
    end
  end

  # GET /e2e/processor/fail
  def fail(conn, params) do
    count = params |> Map.get("count", "1") |> String.to_integer()
    ProcessorState.set_fail(count)
    json(conn, %{ok: true, fail_count: count})
  end

  # GET /e2e/processor/reset
  def reset(conn, _params) do
    ProcessorState.reset()
    json(conn, %{ok: true})
  end

  # POST /e2e/reset — describe-level teardown. Truncates mutable tables and
  # re-seeds the deterministic fixtures bootstrap.exs creates.
  def reset_all(conn, _params) do
    :ok = Reset.run()
    json(conn, %{ok: true})
  end

  # POST /e2e/system-config with JSON body: {"key": "...", "value": "..."}
  def set_system_config(conn, params) do
    key = Map.get(params, "key")
    value = Map.get(params, "value")

    if is_binary(key) and key != "" do
      case Zaq.System.set_config(key, value) do
        {:ok, _} ->
          json(conn, %{ok: true, key: key, value: value})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(:bad_request) |> json(%{error: "missing key"})
    end
  end

  # POST /e2e/ingestion/touch_file?path=knowledge/benefits.md
  # Bumps the mtime of a file inside tmp/e2e_documents/ so stale detection
  # fires without Playwright having to sleep for filesystem granularity.
  def touch_file(conn, params) do
    case Map.get(params, "path") do
      path when is_binary(path) and path != "" ->
        {:ok, absolute} = Reset.touch_file!(path)
        json(conn, %{ok: true, path: absolute})

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "missing path"}) |> halt()
    end
  end

  # GET /e2e/health
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      env: "test",
      e2e: true,
      node: node()
    })
  end

  # GET /e2e/telemetry/points?metric=ingestion.*&limit=50&last_minutes=5
  def telemetry_points(conn, params) do
    points = Telemetry.list_recent_points(params)
    metric = Map.get(params, "metric", "")

    json(conn, %{
      points: Enum.map(points, &serialize_point/1),
      count: length(points),
      metric: metric
    })
  end

  # GET /e2e/logs/recent?level=error&limit=20
  def logs_recent(conn, params) do
    limit = params |> Map.get("limit", "100") |> parse_int(100)
    level = Map.get(params, "level", nil)

    opts = [limit: limit] ++ if(level, do: [level: level], else: [])
    logs = LogCollector.recent(opts)

    json(conn, %{
      logs: Enum.map(logs, &serialize_log/1),
      count: length(logs)
    })
  end

  # POST /e2e/llm/v1/chat/completions — fake OpenAI-compatible LLM endpoint.
  # Replaces the old LLMRunnerFake behaviour now that the agent pipeline uses
  # ReqLLM directly (Jido AI + ReqLLM) rather than the LLMRunnerBehaviour.
  #
  # Detects call type by system prompt content:
  #   - Retrieval prompt contains "positive_answer" → return JSON query struct
  #   - Answering prompt does not → return baseline/tuned text with source citation
  #
  # Jido AI's answering agent uses SSE streaming; retrieval uses regular JSON.
  # We detect via the "stream" field in the request body.
  def fake_llm(conn, _params) do
    messages = conn.body_params |> Map.get("messages", [])
    streaming? = conn.body_params |> Map.get("stream", false)

    system_content =
      messages |> Enum.find(%{}, &(Map.get(&1, "role") == "system")) |> Map.get("content", "")

    content = fake_llm_content(messages, system_content)

    if streaming? do
      fake_llm_stream(conn, content)
    else
      json(conn, %{
        "id" => "e2e-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      })
    end
  end

  defp fake_llm_content(messages, system_content) do
    if retrieval_call?(system_content) do
      user_content =
        messages |> Enum.find(%{}, &(Map.get(&1, "role") == "user")) |> Map.get("content", "")

      Jason.encode!(%{
        "query" => String.trim(user_content),
        "language" => "eng",
        "positive_answer" => "Searching your knowledge base...",
        "negative_answer" => "No relevant information found in your knowledge base."
      })
    else
      sources = extract_llm_sources(system_content)
      source = List.first(sources)
      tuned? = String.contains?(system_content, "E2E_PROMPT_VARIANT_B")

      body =
        if tuned?,
          do: "Tuned response generated from the updated prompt template.",
          else: "Baseline response generated from the default prompt template."

      if is_binary(source),
        do: "#{body} [[source:#{source}]]",
        else: "#{body} [[memory:llm-general-knowledge]]"
    end
  end

  defp fake_llm_stream(conn, content) do
    id = "e2e-#{System.unique_integer([:positive])}"

    chunks = [
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => nil
          }
        ]
      }),
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [%{"index" => 0, "delta" => %{"content" => content}, "finish_reason" => nil}]
      }),
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })
    ]

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk_json, conn ->
      {:ok, conn} = chunk(conn, "data: #{chunk_json}\n\n")
      conn
    end)
    |> then(fn conn ->
      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
    end)
  end

  defp retrieval_call?(system_content),
    do: String.contains?(system_content, "positive_answer")

  defp extract_llm_sources(system_content) do
    ~r/"source"\s*:\s*"([^"]+)"/
    |> Regex.scan(system_content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp serialize_point(point) do
    %{
      metric_key: point.metric_key,
      value: point.value,
      occurred_at: DateTime.to_iso8601(point.occurred_at),
      dimensions: point.dimensions,
      source: point.source,
      node: point.node
    }
  end

  defp serialize_log(entry) do
    %{
      level: entry.level,
      message: entry.message,
      timestamp: DateTime.to_iso8601(entry.timestamp)
    }
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
