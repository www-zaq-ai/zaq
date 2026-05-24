defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPFeedback do
  @moduledoc """
  User-facing MCP feedback helpers for test failures and runtime warnings.
  """

  def test_failure_message(reason) do
    cond do
      capabilities_not_ready?(reason) ->
        "MCP tools test failed: server handshake not ready yet (capabilities not set). Please retry in a moment."

      endpoint_already_registered?(reason) ->
        "MCP tools test failed: stale test endpoint state detected and was reset. Please retry."

      unauthorized_error?(reason) ->
        "MCP tools test failed: unauthorized (401). Please check MCP authentication headers/credentials."

      runtime_call_exit?(reason) ->
        "MCP tools test failed: MCP client disconnected during request. Please retry."

      true ->
        "MCP tools test failed: #{inspect(reason)}"
    end
  end

  def maybe_put_runtime_warnings(socket, payload) when is_map(payload) do
    warnings = runtime_warnings(payload)

    if warnings == [] do
      socket
    else
      Phoenix.LiveView.put_flash(socket, :warning, "MCP runtime warnings: #{inspect(warnings)}")
    end
  end

  def maybe_put_runtime_warnings(socket, _), do: socket

  def runtime_warnings(payload) when is_map(payload) do
    payload
    |> map_get(:runtime, %{})
    |> map_get(:warnings, [])
  end

  def runtime_warnings(_), do: []

  defp capabilities_not_ready?(reason) do
    reason
    |> inspect()
    |> String.contains?("Server capabilities not set")
  end

  defp endpoint_already_registered?(reason) do
    reason
    |> inspect()
    |> String.contains?("endpoint_already_registered")
  end

  defp unauthorized_error?(reason) do
    rendered = inspect(reason)

    String.contains?(rendered, "http_error, 401") or
      String.contains?(rendered, "unauthorized") or
      String.contains?(rendered, "AuthenticateToken authentication failed")
  end

  defp runtime_call_exit?(reason) do
    reason
    |> inspect()
    |> String.contains?("mcp_runtime_call_exit")
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
