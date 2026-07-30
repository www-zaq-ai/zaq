defmodule Zaq.Records.Content do
  @moduledoc """
  Puts bytes on a record and takes them off again.

  Every strategy needs this and none of them should reinvent it: a second encoding convention
  on the same struct is how a consumer ends up base64-decoding text.

  ## The convention

  | File is | `content` | `attributes["encoding"]` |
  | --- | --- | --- |
  | valid UTF-8 | the text | `"utf8"` |
  | anything else | `Base.encode64/1` of the bytes | `"base64"` |

  This is not new — `Zaq.Ingestion.RecordSource` already reads exactly this key when storing
  an external download. We join that convention rather than inventing a second.

  ## Acceptance, not conversion

  `as` says what the **caller can accept**, not what it wants the bytes turned into. Nobody
  can ask for a PNG "as text": `:text` refuses non-UTF-8 with `{:error, :invalid_utf8}`,
  `:binary` always encodes, `:auto` detects. Refusing is the right answer for a text-only
  caller — handing a model base64 costs context and conveys nothing.

  ## Size is always raw

  `:size` is set to the **decoded** byte count even when `content` is base64. A cap has to
  mean the same number on both sides of a node boundary, and base64 inflates by 4/3.
  """

  alias Zaq.Contracts.Record

  @type acceptance :: :auto | :text | :binary

  @doc """
  Places `bytes` on the record, encoding per `as`, and sets `:size` to the raw byte count.
  """
  @spec put(Record.t(), binary(), acceptance()) :: {:ok, Record.t()} | {:error, :invalid_utf8}
  def put(%Record{} = record, bytes, as) when is_binary(bytes) do
    with {:ok, {content, encoding}} <- encode(bytes, as) do
      {:ok,
       %Record{
         record
         | content: content,
           size: byte_size(bytes),
           attributes: record |> attributes() |> Map.put("encoding", encoding)
       }}
    end
  end

  @doc "Encodes raw bytes for transport, returning the content and its encoding label."
  @spec encode(binary(), acceptance()) :: {:ok, {binary(), String.t()}} | {:error, :invalid_utf8}
  def encode(bytes, :binary) when is_binary(bytes), do: {:ok, {Base.encode64(bytes), "base64"}}

  def encode(bytes, as) when is_binary(bytes) and as in [:auto, :text] do
    cond do
      String.valid?(bytes) -> {:ok, {bytes, "utf8"}}
      as == :text -> {:error, :invalid_utf8}
      true -> {:ok, {Base.encode64(bytes), "base64"}}
    end
  end

  @doc """
  Recovers the raw bytes from a materialized record.

  A record with no `encoding` attribute is taken at face value — that covers records built
  before this convention existed and ones carrying plain text.
  """
  @spec decode(Record.t()) ::
          {:ok, binary()} | {:error, :no_content | :invalid_base64 | :unsupported_content}
  def decode(%Record{content: nil}), do: {:error, :no_content}

  def decode(%Record{content: content} = record) when is_binary(content) do
    if encoding(record) == "base64" do
      case Base.decode64(content) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :invalid_base64}
      end
    else
      {:ok, content}
    end
  end

  def decode(%Record{}), do: {:error, :unsupported_content}

  @doc "The raw byte count of a record's content, whatever its encoding."
  @spec raw_size(Record.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def raw_size(%Record{} = record) do
    with {:ok, bytes} <- decode(record), do: {:ok, byte_size(bytes)}
  end

  @doc "The record's declared content encoding, or `nil`."
  @spec encoding(Record.t()) :: String.t() | nil
  def encoding(%Record{} = record) do
    attrs = attributes(record)
    Map.get(attrs, "encoding") || Map.get(attrs, :encoding)
  end

  defp attributes(%Record{attributes: attrs}) when is_map(attrs), do: attrs
  defp attributes(%Record{}), do: %{}
end
