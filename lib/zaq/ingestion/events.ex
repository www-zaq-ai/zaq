defmodule Zaq.Ingestion.Events do
  @moduledoc """
  Standardized Ingestion role event builders and dispatchers.
  """

  alias Zaq.Event
  alias Zaq.Events.Helper

  @doc "Dispatches a confidential document/label metadata query to the Ingestion role."
  @spec build_and_dispatch_query_resources_event(map(), keyword()) :: Event.t()
  def build_and_dispatch_query_resources_event(request, opts \\ []) when is_map(request) do
    opts =
      Keyword.update(
        opts,
        :event_opts,
        [confidential: true],
        &Keyword.put(&1, :confidential, true)
      )

    Helper.build_and_dispatch_invoke_event(:ingestion, request, :query_resources, opts)
  end

  @doc "Builds an Ingestion event that reads a document's bytes off its volume."
  @spec build_materialize_document_event(map(), keyword()) :: Event.t()
  def build_materialize_document_event(request, opts \\ []) when is_map(request) do
    Helper.build_invoke_event(:ingestion, request, :materialize_document, opts)
  end

  @spec build_and_dispatch_materialize_document_event(map(), keyword()) :: Event.t()
  def build_and_dispatch_materialize_document_event(request, opts \\ []) when is_map(request) do
    Helper.build_and_dispatch_invoke_event(:ingestion, request, :materialize_document, opts)
  end
end
