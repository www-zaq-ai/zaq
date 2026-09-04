defmodule Zaq.Storage.Materializers.DiskDocument do
  @moduledoc """
  Materializes documents held on storage volumes through the Storage role.

  The locator names the file by its source — volume plus relative path — which is the id
  `Zaq.Channels.DiskBridge` puts on every record it returns. No document row is read, so a
  file that was never ingested materializes exactly like one that was.
  """

  @behaviour Zaq.Materialization.Handler

  alias Zaq.Events.TrustedContext
  alias Zaq.Helpers
  alias Zaq.Materialization
  alias Zaq.Storage.Events

  @type_key "disk_document"
  @locator_fields ~w(config_id)

  @doc "Issues a handle for the document a volume source names."
  @spec issue(String.t(), map() | keyword(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def issue(file_id, attrs_or_opts \\ %{}, opts \\ [])

  def issue(file_id, opts, []) when is_binary(file_id) and is_list(opts),
    do: issue(file_id, %{}, opts)

  def issue(file_id, attrs, opts) when is_binary(file_id) and is_map(attrs) and is_list(opts) do
    locator =
      attrs
      |> Map.take(@locator_fields)
      |> Map.merge(%{"file_id" => file_id})
      |> drop_blank_values()

    Materialization.issue(@type_key, locator, opts)
  end

  def issue(_file_id, _attrs_or_opts, _opts), do: {:error, :invalid_materialization_locator}

  @doc "Reads the bytes by dispatching the fixed `:materialize_document` action to Storage."
  @impl true
  def materialization_options, do: Zaq.Materialization.document_mime_options()

  @impl true
  def materialize(locator, context, options \\ %{})

  def materialize(locator, context, options),
    do: Zaq.Materialization.materialize_with_handler(__MODULE__, locator, context, options)

  @impl true
  def do_materialize(locator, context, options)

  def do_materialize(locator, context, options)
      when is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, request} <- validate_locator(locator) do
      request
      |> Events.build_and_dispatch_materialize_document_event(
        TrustedContext.event_builder_opts(context)
      )
      |> Map.fetch!(:response)
    end
  end

  def do_materialize(_locator, _context, _options), do: {:error, :invalid_materialization_locator}

  # The source is the whole locator: anything else a tampered handle carries is ignored
  # rather than forwarded to ingestion.
  defp validate_locator(locator) do
    case Map.get(locator, "file_id") do
      file_id when is_binary(file_id) ->
        if Helpers.blank?(file_id),
          do: {:error, :invalid_materialization_locator},
          else:
            {:ok,
             locator
             |> Map.take(@locator_fields)
             |> Map.put(:file_id, file_id)
             |> drop_blank_values()}

      _other ->
        {:error, :invalid_materialization_locator}
    end
  end

  defp drop_blank_values(map) do
    Map.reject(map, fn {_key, value} -> Helpers.blank?(value) end)
  end
end
