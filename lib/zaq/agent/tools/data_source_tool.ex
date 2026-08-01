defmodule Zaq.Agent.Tools.DataSourceTool do
  @moduledoc """
  Shared dispatch and response handling for datasource-backed agent tools.
  """

  alias Zaq.Agent.Tools.Error
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

  @doc """
  Builds the event that fetches a document's content from a datasource.

  Carried on an unmaterialized `Zaq.Contracts.Record` so whoever ends up needing the bytes
  can fetch them without knowing which provider holds the file, let alone where. The agent
  node composes this from a provider key and a document id only — it never sees a path.

  The `{role, action}` pair must be whitelisted by `Zaq.Contracts.Record.Materializer`, or
  materializing the record is refused.
  """
  @spec materializing_event(String.t(), map(), keyword()) :: Event.t()
  def materializing_event(provider, params, opts \\ [])
      when is_binary(provider) and is_map(params) do
    params
    |> wrap_request(provider)
    |> Event.new(:channels, Keyword.merge([opts: [action: :data_source_download_document]], opts))
  end

  defp default_on_ok(payload), do: {:ok, payload}
end
