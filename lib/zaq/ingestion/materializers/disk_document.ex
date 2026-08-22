defmodule Zaq.Ingestion.Materializers.DiskDocument do
  @moduledoc """
  Materializes documents held on ingestion volumes through the Ingestion role.

  The locator names the file by its source — volume plus relative path — which is the id
  `Zaq.Channels.DiskBridge` puts on every record it returns. No document row is read, so a
  file that was never ingested materializes exactly like one that was.
  """

  @behaviour Zaq.Materialization.Handler

  alias Zaq.Helpers
  alias Zaq.Ingestion.Events
  alias Zaq.Materialization

  @type_key "disk_document"
  @option_fields ~w(encoding)

  @doc "Issues a handle for the document a volume source names."
  @spec issue(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def issue(file_id, opts \\ [])

  def issue(file_id, opts) when is_binary(file_id),
    do: Materialization.issue(@type_key, %{"file_id" => file_id}, opts)

  def issue(_file_id, _opts), do: {:error, :invalid_materialization_locator}

  @doc "Reads the bytes by dispatching the fixed `:materialize_document` action to Ingestion."
  @impl true
  def materialize(locator, context, options \\ %{})

  def materialize(locator, context, options)
      when is_map(locator) and is_map(context) and is_map(options) do
    with {:ok, file_id} <- validate_locator(locator),
         {:ok, request} <- merge_options(%{file_id: file_id}, options) do
      request
      |> Events.build_and_dispatch_materialize_document_event(node_router_opts(context))
      |> Map.fetch!(:response)
    end
  end

  def materialize(_locator, _context, _options), do: {:error, :invalid_materialization_locator}

  # The source is the whole locator: anything else a tampered handle carries is ignored
  # rather than forwarded to ingestion.
  defp validate_locator(locator) do
    case Map.get(locator, "file_id") do
      file_id when is_binary(file_id) ->
        if Helpers.blank?(file_id),
          do: {:error, :invalid_materialization_locator},
          else: {:ok, file_id}

      _other ->
        {:error, :invalid_materialization_locator}
    end
  end

  # `encoding` is request-time representation state, not document identity, so it arrives as
  # a redemption option rather than inside the signed locator.
  defp merge_options(request, options) do
    case Map.keys(options) -- @option_fields do
      [] -> {:ok, put_encoding(request, Map.get(options, "encoding"))}
      _unknown -> {:error, :invalid_materialization_options}
    end
  end

  defp put_encoding(request, encoding) when is_binary(encoding) do
    if Helpers.blank?(encoding), do: request, else: Map.put(request, :encoding, encoding)
  end

  defp put_encoding(request, _encoding), do: request

  defp node_router_opts(context) do
    case Map.get(context, :node_router) do
      nil -> []
      module -> [node_router: module]
    end
  end
end
