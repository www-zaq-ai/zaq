defmodule Zaq.Agent.Tools.DataSourceTool do
  @moduledoc """
  Shared dispatch and response handling for datasource-backed agent tools.
  """

  alias Zaq.Agent.Tools.Error
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter

  @type on_ok :: (map() -> {:ok, map()} | {:error, String.t()})

  @spec dispatch(atom(), map(), map(), String.t(), on_ok()) :: {:ok, map()} | {:error, String.t()}
  def dispatch(action, request, context, error_prefix, on_ok \\ &default_on_ok/1)

  def dispatch(action, request, context, error_prefix, on_ok) do
    node_router = Map.get(context, :node_router, NodeRouter)
    event = Event.new(request, :channels, opts: [action: action])

    event
    |> node_router.dispatch()
    |> Map.fetch!(:response)
    |> format_response(error_prefix, on_ok)
  end

  @spec format_response(term(), String.t(), on_ok()) :: {:ok, map()} | {:error, String.t()}
  def format_response({:ok, payload}, _error_prefix, on_ok) when is_map(payload),
    do: on_ok.(payload)

  def format_response({:error, reason}, error_prefix, _on_ok) do
    {:error, "#{error_prefix}: #{Error.format(reason)}"}
  end

  def format_response(other, _error_prefix, _on_ok) do
    {:error, "Unexpected data source response: #{inspect(other)}"}
  end

  @doc """
  Fills in a record's content when the bridge answered with an unmaterialized one.

  A bridge whose bytes already sit inside ZAQ returns `content: nil` and a
  `materializing_event` instead of carrying the payload back through the channels node — the
  disk data source does this, since its files live on an ingestion volume. Dispatching that
  event is the second hop that actually reads them.

  A payload that already has content, or a record with no event to dispatch, passes through
  untouched — so a caller can run this over any provider's answer.

  The event answers with the bytes alone, not a record: whoever holds the record already has
  the metadata, and rebuilding it on the far side would mean two places shaping the same
  record. The bytes are merged into the record here.

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
    case Map.get(answer, :encoding) || Map.get(answer, "encoding") do
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

  @spec put_if_present(map(), String.t(), any()) :: map()
  def put_if_present(map, _key, nil), do: map
  def put_if_present(map, key, value), do: Map.put(map, key, value)

  @spec put_many_if_present(map(), [{String.t(), any()}]) :: map()
  def put_many_if_present(map, entries) when is_map(map) and is_list(entries) do
    Enum.reduce(entries, map, fn {key, value}, acc ->
      put_if_present(acc, key, value)
    end)
  end

  @spec merge_optional(map(), map(), [atom()]) :: map()
  def merge_optional(base, params, keys)
      when is_map(base) and is_map(params) and is_list(keys) do
    Enum.reduce(keys, base, fn key, acc ->
      put_if_present(acc, Atom.to_string(key), Map.get(params, key))
    end)
  end

  @spec wrap_request(map(), String.t()) :: map()
  def wrap_request(params, provider) when is_map(params) and is_binary(provider),
    do: %{provider: provider, params: params}

  defp default_on_ok(payload), do: {:ok, payload}
end
