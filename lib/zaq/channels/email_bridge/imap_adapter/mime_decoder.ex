defmodule Zaq.Channels.EmailBridge.ImapAdapter.MimeDecoder do
  @moduledoc false

  @spec decode_body(binary(), term(), map()) :: {:ok, binary()} | {:error, term()}
  def decode_body(binary, encoding, params \\ %{}) when is_binary(binary) do
    with {:ok, decoded} <- decode_attachment(binary, encoding) do
      {:ok, normalize_charset(decoded, charset(params))}
    end
  end

  @spec decode_attachment(binary(), term()) :: {:ok, binary()} | {:error, term()}
  def decode_attachment(binary, encoding) when is_binary(binary) do
    case normalize_encoding(encoding) do
      "base64" -> decode_base64(binary)
      "quoted-printable" -> decode_quoted_printable(binary)
      encoding when encoding in [nil, "7bit", "8bit", "binary"] -> {:ok, binary}
      _unknown -> {:ok, binary}
    end
  end

  def decode_attachment(_binary, _encoding), do: {:error, :invalid_mime_content}

  defp decode_base64(binary) do
    binary
    |> String.replace(~r/\s+/, "")
    |> Base.decode64()
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :decode_failed}
    end
  end

  defp decode_quoted_printable(binary) do
    decoded =
      binary
      |> String.replace(~r/=\r?\n/, "")
      |> String.replace(~r/=([0-9A-Fa-f]{2})/, fn <<"=", hex::binary-size(2)>> ->
        hex |> String.to_integer(16) |> List.wrap() |> :erlang.list_to_binary()
      end)

    {:ok, decoded}
  end

  defp normalize_charset(binary, nil), do: binary
  defp normalize_charset(binary, "utf-8"), do: binary
  defp normalize_charset(binary, "us-ascii"), do: binary
  defp normalize_charset(binary, _charset), do: binary

  defp charset(params) when is_map(params) do
    params
    |> Map.get("charset", Map.get(params, :charset))
    |> normalize_encoding()
  end

  defp charset(_params), do: nil

  defp normalize_encoding(nil), do: nil

  defp normalize_encoding(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end
end
