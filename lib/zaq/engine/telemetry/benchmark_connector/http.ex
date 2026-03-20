defmodule Zaq.Engine.Telemetry.BenchmarkConnector.HTTP do
  @moduledoc """
  Req-based HTTP connector used for telemetry benchmark synchronization.
  """

  @behaviour Zaq.Engine.Telemetry.BenchmarkConnector

  alias Zaq.Engine.Telemetry

  @impl true
  def push_rollups(payload) do
    request(:post, "/api/v1/telemetry/rollups", payload)
  end

  @impl true
  def pull_rollups(payload) do
    request(:post, "/api/v1/telemetry/benchmarks", payload)
  end

  defp request(method, path, payload) do
    req_opts = [
      method: method,
      url: Telemetry.remote_url() <> path,
      json: payload,
      headers: build_headers(),
      receive_timeout: 30_000
    ]

    req_opts = Keyword.merge(req_opts, Telemetry.req_options())

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        if method == :post and path == "/api/v1/telemetry/rollups" do
          :ok
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:remote_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers do
    token = Telemetry.remote_token()

    if token in [nil, ""] do
      []
    else
      [{"authorization", "Bearer #{token}"}]
    end
  end
end
