defmodule Zaq.Utils.EmailUtils do
  @moduledoc false

  @doc """
  Strips angle brackets and whitespace from an RFC 2822 Message-ID value.
  Returns `nil` for blank or non-binary input.
  """
  def normalize_message_id(nil), do: nil

  def normalize_message_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_message_id(_), do: nil
end
