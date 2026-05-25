defmodule Zaq.Channels.MessageCorrelation do
  @moduledoc """
  Correlates channel request ids with provider message ids.
  """

  @table :zaq_channels_message_correlation

  @spec put(atom() | String.t(), String.t(), String.t()) :: :ok
  def put(provider, request_id, message_id)
      when is_binary(request_id) and request_id != "" and is_binary(message_id) and
             message_id != "" do
    table = ensure_table()
    :ets.insert(table, {key(provider, request_id), message_id})
    :ok
  end

  def put(_provider, _request_id, _message_id), do: :ok

  @spec get(atom() | String.t(), String.t()) :: {:ok, String.t()} | :error
  def get(provider, request_id) when is_binary(request_id) and request_id != "" do
    table = ensure_table()

    case :ets.lookup(table, key(provider, request_id)) do
      [{_, message_id}] when is_binary(message_id) and message_id != "" -> {:ok, message_id}
      _ -> :error
    end
  end

  def get(_provider, _request_id), do: :error

  @spec delete(atom() | String.t(), String.t()) :: :ok
  def delete(provider, request_id) when is_binary(request_id) and request_id != "" do
    table = ensure_table()
    :ets.delete(table, key(provider, request_id))
    :ok
  end

  def delete(_provider, _request_id), do: :ok

  defp key(provider, request_id) when is_atom(provider),
    do: {Atom.to_string(provider), request_id}

  defp key(provider, request_id), do: {to_string(provider), request_id}

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

      table ->
        table
    end
  end
end
