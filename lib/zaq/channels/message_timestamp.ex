defmodule Zaq.Channels.MessageTimestamp do
  @moduledoc """
  Converts transport timestamps into UTC instants before crossing into Engine.
  Callers select the transport's documented format; unknown dates remain absent.
  """

  alias Mail.Parsers.RFC2822

  @doc "Normalizes a provider timestamp without substituting receive time."
  def normalize(%DateTime{} = value, _format), do: DateTime.shift_zone!(value, "Etc/UTC")

  def normalize(value, unit) when is_integer(value) and unit in [:second, :millisecond] do
    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> datetime
      _ -> nil
    end
  end

  def normalize(value, :iso8601) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def normalize(value, :rfc2822) when is_binary(value) do
    case RFC2822.to_datetime(value) do
      %DateTime{} = datetime -> normalize(datetime, :iso8601)
      _ -> nil
    end
  end

  def normalize(_, _), do: nil
end
