defmodule Zaq.Channels.Materializers.DataSourceDocument do
  @moduledoc """
  Materializes data-source documents through the Channels role.
  """

  @behaviour Zaq.Materialization.Handler

  alias Zaq.Channels.Events
  alias Zaq.Events.TrustedContext
  alias Zaq.Helpers

  @type_key "data_source_document"
  @locator_fields ~w(config_id document_mime_type)
  @option_fields ~w(document_mime_type export_mime_type)

  @spec issue(atom() | String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def issue(provider, file_id, attrs \\ %{}, opts \\ [])
      when is_binary(file_id) and is_map(attrs) do
    locator =
      attrs
      |> Map.take(@locator_fields)
      |> Map.merge(%{"provider" => to_string(provider), "file_id" => file_id})
      |> drop_blank_values()

    Zaq.Materialization.issue(@type_key, locator, opts)
  end

  @impl true
  def materialize(locator, context, options \\ %{})

  def materialize(locator, context, options)
      when is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, provider, params} <- validate_locator(locator),
         {:ok, params} <- merge_options(params, options) do
      provider
      |> Events.build_and_dispatch_data_source_download_document_event(
        params,
        TrustedContext.event_builder_opts(context,
          event_opts: data_source_event_opts(context)
        )
      )
      |> Map.fetch!(:response)
    end
  end

  def materialize(_locator, _context, _options), do: {:error, :invalid_materialization_locator}

  defp validate_locator(locator) do
    provider = string(locator, "provider")
    file_id = string(locator, "file_id")

    cond do
      blank?(provider) ->
        {:error, :invalid_materialization_locator}

      blank?(file_id) ->
        {:error, :invalid_materialization_locator}

      true ->
        params =
          locator
          |> Map.take(@locator_fields)
          |> Map.put("file_id", file_id)
          |> drop_blank_values()

        {:ok, provider, params}
    end
  end

  defp merge_options(params, options) do
    case Map.keys(options) -- @option_fields do
      [] -> {:ok, params |> Map.merge(Map.take(options, @option_fields)) |> drop_blank_values()}
      _unknown -> {:error, :invalid_materialization_options}
    end
  end

  defp data_source_event_opts(context) do
    case Map.get(context, :data_source_bridge_module) do
      nil -> []
      module -> [data_source_bridge_module: module]
    end
  end

  defp string(map, key), do: string_value(Map.get(map, key))

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp blank?(value), do: !is_binary(value) or Helpers.blank?(value)

  defp drop_blank_values(map) do
    Map.reject(map, fn {_key, value} -> Helpers.blank?(value) end)
  end
end
