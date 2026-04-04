defmodule Zaq.E2E.LogHandler do
  @moduledoc false

  alias Zaq.E2E.LogCollector

  @doc "Erlang logger handler callback — called when handler is installed."
  def adding_handler(config), do: {:ok, config}

  @doc "Erlang logger handler callback — called for each log event."
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    LogCollector.push(%{
      level: level,
      message: format_message(msg),
      timestamp: erlang_time_to_datetime(Map.get(meta, :time))
    })
  end

  defp format_message({:string, msg}) when is_binary(msg), do: msg
  defp format_message({:string, msg}), do: IO.chardata_to_string(msg)

  defp format_message({format, args}) when is_list(args) do
    :io_lib.format(format, args) |> IO.chardata_to_string()
  rescue
    _ -> inspect({format, args})
  end

  defp format_message(msg), do: inspect(msg)

  defp erlang_time_to_datetime(nil), do: DateTime.utc_now()

  defp erlang_time_to_datetime(microseconds) when is_integer(microseconds) do
    DateTime.from_unix!(microseconds, :microsecond)
  end
end
