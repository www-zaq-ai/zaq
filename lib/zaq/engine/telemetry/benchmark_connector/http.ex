defmodule Zaq.Engine.Telemetry.BenchmarkConnector.HTTP do
  @moduledoc """
  Req-based HTTP connector used for telemetry benchmark synchronization.
  """

  @behaviour Zaq.Engine.Telemetry.BenchmarkConnector

  alias Zaq.Engine.Telemetry

  @impl true
  def push_rollups(payload) do
    req_opts = build_req_opts(:post, "/api/v1/telemetry/rollups", payload)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:remote_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def pull_rollups(payload) do
    req_opts = build_req_opts(:post, "/api/v1/telemetry/benchmarks", payload)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:remote_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_req_opts(method, path, payload) do
    req_opts = [
      method: method,
      url: Telemetry.remote_url() <> path,
      json: payload,
      headers: build_headers(),
      receive_timeout: 30_000
    ]

    Keyword.merge(req_opts, Telemetry.req_options())
  end

  defp build_headers do
    token = Telemetry.remote_token()

    if token == "" do
      []
    else
      [{"authorization", "Bearer #{token}"}]
    end
  end
end
