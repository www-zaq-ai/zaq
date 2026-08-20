defmodule Zaq.Materialization.Registry do
  @moduledoc """
  Static allowlist of materialization handlers.
  """

  @handlers %{
    "data_source_document" => Zaq.Channels.Materializers.DataSourceDocument
  }

  @spec lookup(String.t()) :: {:ok, module()} | {:error, {:unknown_materializer, term()}}
  def lookup(type) when is_binary(type) do
    case Map.fetch(@handlers, type) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, {:unknown_materializer, type}}
    end
  end

  def lookup(type), do: {:error, {:unknown_materializer, type}}
end
