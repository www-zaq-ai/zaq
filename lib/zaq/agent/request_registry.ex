defmodule Zaq.Agent.RequestRegistry do
  @moduledoc """
  Lightweight registry for in-flight agent requests.

  The registry stores inspectable realtime state keyed by request id. It is used
  by the Agent API to expose request inspection and to route steer/inject signals
  to the active agent server.
  """

  use GenServer

  @table :zaq_agent_request_registry

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @spec put(String.t(), map()) :: :ok
  def put(request_id, attrs) when is_binary(request_id) and is_map(attrs) do
    with table when table != :undefined <- table_ref() do
      current =
        get(request_id)
        |> case do
          {:ok, state} -> state
          _ -> %{}
        end

      :ets.insert(table, {request_id, Map.merge(current, attrs)})
    end

    :ok
  end

  def put(_request_id, _attrs), do: :ok

  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(request_id) when is_binary(request_id) do
    case table_ref() do
      :undefined ->
        {:error, :not_found}

      table ->
        case :ets.lookup(table, request_id) do
          [{^request_id, state}] -> {:ok, state}
          [] -> {:error, :not_found}
        end
    end
  end

  def get(_request_id), do: {:error, :not_found}

  @spec delete(String.t()) :: :ok
  def delete(request_id) when is_binary(request_id) do
    with table when table != :undefined <- table_ref() do
      :ets.delete(table, request_id)
    end

    :ok
  end

  def delete(_request_id), do: :ok

  defp table_ref, do: :ets.whereis(@table)
end
