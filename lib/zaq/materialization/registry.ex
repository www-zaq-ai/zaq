defmodule Zaq.Materialization.Registry do
  @moduledoc """
  Static allowlist of materialization handlers.
  """

  @handlers %{
    "communication_media" => Zaq.Channels.Materializers.CommunicationMedia,
    "data_source_document" => Zaq.Channels.Materializers.DataSourceDocument,
    "disk_document" => Zaq.Storage.Materializers.DiskDocument
  }

  @spec lookup(String.t()) :: {:ok, module()} | {:error, {:unknown_materializer, term()}}
  def lookup(type) when is_binary(type) do
    case Map.fetch(@handlers, type) do
      {:ok, handler} -> {:ok, handler}
      :error -> {:error, {:unknown_materializer, type}}
    end
  end

  def lookup(type), do: {:error, {:unknown_materializer, type}}

  @doc "Routes a verified document locator to its acquisition or byte handler."
  def resolve("disk_document", %{"config_id" => id} = locator, options)
      when is_integer(id) or (is_binary(id) and id != "") do
    case Map.get(options, "required_record_fields") do
      [_ | _] ->
        locator = locator |> Map.put("provider", "disk") |> Map.put("config_id", to_string(id))
        {:ok, Zaq.Channels.Materializers.DataSourceDocument, locator, options}

      _ ->
        resolve_by_type("disk_document", locator, options)
    end
  end

  def resolve(type, locator, options), do: resolve_by_type(type, locator, options)

  defp resolve_by_type("data_source_document" = type, locator, options) do
    with {:ok, handler} <- lookup(type), do: {:ok, handler, locator, options}
  end

  defp resolve_by_type(type, locator, options) do
    with {:ok, handler} <- lookup(type) do
      {:ok, handler, locator, Map.delete(options, "required_record_fields")}
    end
  end
end
