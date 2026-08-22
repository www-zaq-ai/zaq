defmodule Zaq.Ingestion.Events do
  @moduledoc """
  Standardized Ingestion role event builders and dispatchers.
  """

  alias Zaq.Event
  alias Zaq.Events.Helper

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
