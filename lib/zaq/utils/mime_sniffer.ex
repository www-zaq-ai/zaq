defmodule Zaq.Utils.MimeSniffer do
  @moduledoc """
  Identifies a binary's media type from its leading bytes.

  Some providers hand over media with neither a filename nor a declared type — Telegram
  photos arrive with both fields empty — which leaves nothing for `MIME.from_path/1` to work
  from. The bytes themselves still say what they are, so they are read directly.

  Only formats worth acting on are recognised. Anything else answers `nil`, which callers
  read as "unknown" and handle the way they already handle a provider that declared nothing.
  """

  @doc """
  The MIME type of `binary`, or `nil` when its signature is not recognised.

  ## Examples

      iex> Zaq.Utils.MimeSniffer.detect(<<0xFF, 0xD8, 0xFF, 0xE0, 0x00>>)
      "image/jpeg"

      iex> Zaq.Utils.MimeSniffer.detect("just some text")
      nil
  """
  @spec detect(binary()) :: String.t() | nil
  def detect(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  def detect(<<0x89, "PNG\r\n", 0x1A, "\n", _rest::binary>>), do: "image/png"
  def detect(<<"GIF87a", _rest::binary>>), do: "image/gif"
  def detect(<<"GIF89a", _rest::binary>>), do: "image/gif"
  def detect(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  def detect(<<"RIFF", _size::binary-size(4), "WAVE", _rest::binary>>), do: "audio/wav"
  def detect(<<"BM", _rest::binary>>), do: "image/bmp"
  def detect(<<"%PDF-", _rest::binary>>), do: "application/pdf"
  def detect(<<"OggS", _rest::binary>>), do: "audio/ogg"
  def detect(<<"ID3", _rest::binary>>), do: "audio/mpeg"
  def detect(<<0xFF, 0xFB, _rest::binary>>), do: "audio/mpeg"
  def detect(<<0xFF, 0xF3, _rest::binary>>), do: "audio/mpeg"
  def detect(<<0xFF, 0xF2, _rest::binary>>), do: "audio/mpeg"
  def detect(<<_offset::binary-size(4), "ftyp", _rest::binary>>), do: "video/mp4"
  def detect(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: "video/webm"
  def detect(_binary), do: nil

  @doc """
  Ensures `name` carries an extension matching `mime_type`.

  A provider that sends no filename leaves one derived from the media kind alone, so the
  stored file would have no extension and nothing downstream could infer its type from the
  path. A name that already ends in a matching extension is left alone.
  """
  @spec ensure_extension(String.t(), String.t() | nil) :: String.t()
  def ensure_extension(name, nil) when is_binary(name), do: name

  def ensure_extension(name, mime_type) when is_binary(name) and is_binary(mime_type) do
    case MIME.extensions(mime_type) do
      [] -> name
      extensions -> put_extension(name, extensions)
    end
  end

  def ensure_extension(name, _mime_type), do: name

  defp put_extension(name, [preferred | _] = extensions) do
    current = name |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    if current in extensions, do: name, else: "#{name}.#{preferred}"
  end
end
