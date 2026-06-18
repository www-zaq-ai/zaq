defmodule Zaq.Channels.IngressRuntimeStatus do
  @moduledoc """
  Stores transient ingress runtime status by bridge id.

  This is intentionally process-local and best-effort: it gives BO operators the
  latest listener lifecycle error without making runtime health part of persisted
  channel configuration.
  """

  @table :zaq_channels_ingress_runtime_status

  @spec put(String.t(), map()) :: :ok
  def put(bridge_id, status) when is_binary(bridge_id) and is_map(status) do
    ensure_table!()
    :ets.insert(@table, {bridge_id, Map.put(status, :updated_at, DateTime.utc_now())})
    :ok
  end

  @spec get(String.t()) :: map() | nil
  def get(bridge_id) when is_binary(bridge_id) do
    ensure_table!()

    case :ets.lookup(@table, bridge_id) do
      [{^bridge_id, status}] -> status
      [] -> nil
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(bridge_id) when is_binary(bridge_id) do
    ensure_table!()
    :ets.delete(@table, bridge_id)
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _tid -> @table
    end
  rescue
    ArgumentError -> @table
  end
end
