defmodule Zaq.Contracts.RecordMaterializer do
  @moduledoc """
  Materializes records whose content is available through a trusted event.

  `Zaq.Contracts.Record` stays a pure struct. This module owns the opt-in second
  hop for callers that hold an in-memory record with a dispatchable
  `materializing_event`.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  Fills in a record's content when the bridge answered with an unmaterialized one.

  A bridge whose bytes already sit inside ZAQ returns `content: nil` and a
  `materializing_event` instead of carrying the payload back through the channels node — the
  disk data source does this, since its files live on an ingestion volume. Dispatching that
  event is the second hop that actually reads them.

  A payload that already has content, or a record with no event to dispatch, passes through
  untouched — so a caller can run this over any provider's answer.

  The event may answer with the bytes alone (`%{content: content}`) or with the current
  datasource download response shape (`%{record: %Record{content: content}}`). Whoever holds
  the original record already has the metadata, so the content and optional encoding are merged
  into that original record here.

  Read `attributes["encoding"]` on the result: `"base64"` means the content is encoded bytes,
  and its absence means it is already text.
  """
  @spec materialize(map(), map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def materialize(
        %{record: %Record{content: nil, materializing_event: %Event{} = event} = record} =
          payload,
        context,
        error_prefix
      ) do
    node_router = Map.get(context, :node_router, NodeRouter)

    event
    |> node_router.dispatch()
    |> Map.fetch!(:response)
    |> format_response(error_prefix, fn
      %{record: %Record{content: content} = answer} when not is_nil(content) ->
        {:ok, %{payload | record: put_content(record, content, answer)}}

      %{record: %{content: content} = answer} when not is_nil(content) ->
        {:ok, %{payload | record: put_content(record, content, answer)}}

      %{content: content} = answer ->
        {:ok, %{payload | record: put_content(record, content, answer)}}

      other ->
        {:error, "#{error_prefix}: unexpected materialize response #{inspect(other)}"}
    end)
  end

  def materialize(payload, _context, _error_prefix), do: {:ok, payload}

  # `encoding` travels beside the content rather than inside the record, so it is stamped onto
  # the record's attributes here — the key `RecordSource.store_download/2` reads.
  defp put_content(%Record{} = record, content, answer) do
    case encoding(answer) do
      nil ->
        %{record | content: content}

      encoding ->
        %{
          record
          | content: content,
            attributes: Map.put(record.attributes || %{}, "encoding", encoding)
        }
    end
  end

  defp encoding(%Record{attributes: attrs}) when is_map(attrs),
    do: Map.get(attrs, "encoding") || Map.get(attrs, :encoding)

  defp encoding(answer) when is_map(answer) do
    Map.get(answer, :encoding) || Map.get(answer, "encoding") ||
      answer |> Map.get(:attributes, %{}) |> encoding_from_attrs() ||
      answer |> Map.get("attributes", %{}) |> encoding_from_attrs()
  end

  defp encoding(_), do: nil

  defp encoding_from_attrs(attrs) when is_map(attrs),
    do: Map.get(attrs, "encoding") || Map.get(attrs, :encoding)

  defp encoding_from_attrs(_), do: nil

  defp format_response({:ok, payload}, _error_prefix, on_ok) when is_map(payload),
    do: on_ok.(payload)

  defp format_response({:error, reason}, error_prefix, _on_ok),
    do: {:error, "#{error_prefix}: #{format_reason(reason)}"}

  defp format_response(other, _error_prefix, _on_ok),
    do: {:error, "Unexpected materialize response: #{inspect(other)}"}

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason, limit: 20, printable_limit: 500)
end
