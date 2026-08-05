defmodule Zaq.Agent.Tools.MediaModality do
  @moduledoc """
  Decides whether the running model can read a document, and turns one it can read into a
  `ReqLLM.Message.ContentPart`.

  A tool result is JSON-encoded, so returning image bytes inside it hands the model a large
  string it cannot see. `Jido.AI.Turn.format_tool_result_content/1` looks for a
  `__content_parts__` key on the returned map and emits those as real content blocks
  instead, excluding binary parts from the JSON payload. Building that key is this module's
  job.

  The modalities come from `tool_context[:input_modalities]`, a projection of the model spec
  put there by `Zaq.Agent.ServerManager`. An empty list means unknown rather than
  text-only — a model missing from the LLMDB catalog should not be assumed blind, so the
  attempt is made and the provider gets to reject it.
  """

  alias ReqLLM.Message.ContentPart
  alias Zaq.Contracts.Record

  @doc """
  Whether a document of `mime_type` can be read by a model accepting `modalities`.

  A `nil` mime type is allowed through: the caller has nothing to judge on, and refusing
  would block every document whose provider did not declare a type.
  """
  @spec readable?(String.t() | nil, [atom()]) :: boolean()
  def readable?(nil, _modalities), do: true
  def readable?(_mime_type, []), do: true

  def readable?(mime_type, modalities) when is_binary(mime_type) and is_list(modalities) do
    case modality(mime_type) do
      :text -> true
      required -> required in modalities
    end
  end

  def readable?(_mime_type, _modalities), do: true

  @doc "The input modality a MIME type needs — `:image`, `:audio`, `:video`, or `:text`."
  @spec modality(String.t() | nil) :: :image | :audio | :video | :text
  def modality("image/" <> _rest), do: :image
  def modality("audio/" <> _rest), do: :audio
  def modality("video/" <> _rest), do: :video
  def modality(_mime_type), do: :text

  @doc """
  Explains, for the model to relay, why a document cannot be opened.
  """
  @spec refusal(String.t() | nil, String.t() | nil) :: String.t()
  def refusal(name, mime_type) do
    "This agent's model cannot read #{modality(mime_type)} content, so " <>
      "#{name || "the attachment"} (#{mime_type || "unknown type"}) was not opened. " <>
      "Tell the user the file could not be read and ask them to describe it or send text."
  end

  @doc """
  Adds `__content_parts__` to a tool payload when the record holds media the model can see.

  Text documents pass through untouched — they are already readable in the JSON payload,
  and duplicating them as content parts would send the same bytes twice.
  """
  @spec put_content_parts(map(), [atom()]) :: map()
  def put_content_parts(%{record: %Record{} = record} = payload, modalities) do
    with :image <- modality(record.mime_type),
         true <- :image in modalities,
         {:ok, binary} <- decode(record) do
      payload
      |> Map.put(:record, without_content(record))
      |> Map.put(:__content_parts__, [ContentPart.image(binary, record.mime_type)])
    else
      _ -> payload
    end
  end

  def put_content_parts(payload, _modalities), do: payload

  # The bytes now travel as a content block, and `Record` derives `Jason.Encoder` over
  # `:content` — leaving it set would serialise the same image again as base64 inside the
  # JSON payload, sending a 113 KB photo twice and burning tens of thousands of tokens on a
  # copy the model cannot read anyway.
  defp without_content(%Record{} = record) do
    %{
      record
      | content: nil,
        attributes: Map.put(record.attributes || %{}, "content_delivered_as", "image")
    }
  end

  # `Zaq.Ingestion.materialize_record/1` marks encoded bytes with `attributes["encoding"]`;
  # anything else is already the text it claims to be. ReqLLM re-encodes at the provider
  # boundary, so the part carries raw bytes rather than base64.
  defp decode(%Record{content: content, attributes: attributes}) when is_binary(content) do
    case Map.get(attributes || %{}, "encoding") do
      "base64" -> Base.decode64(content)
      _ -> {:ok, content}
    end
  end

  defp decode(%Record{}), do: :error
end
