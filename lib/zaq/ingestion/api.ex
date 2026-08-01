defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.RecordMaterializer
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(
        %Event{request: %{records: records, params: params}} = event,
        :ingest_records,
        _context
      )
      when is_list(records) and is_map(params) do
    %{event | response: Ingestion.ingest_records(records, params)}
  end

  def handle_event(%Event{request: request} = event, :process_data_source_changes, _context)
      when is_map(request) do
    %{event | response: Ingestion.process_data_source_changes(request)}
  end

  # Record materialization. These four carry the `file_id` ↔ record mapping across the role
  # boundary so no other node needs to know where a document physically lives.
  # `RecordMaterializer` enforces `DocumentAccess` on every read — there is no
  # `skip_permissions` path here, and a `skip_permissions` key in the request is ignored.
  def handle_event(%Event{request: request} = event, :materialize_record, _context)
      when is_map(request) do
    %{event | response: RecordMaterializer.materialize(request)}
  end

  def handle_event(%Event{request: request} = event, :describe_records, _context)
      when is_map(request) do
    %{event | response: RecordMaterializer.describe(request)}
  end

  def handle_event(%Event{request: request} = event, :persist_record, _context)
      when is_map(request) do
    %{event | response: RecordMaterializer.persist(request)}
  end

  def handle_event(%Event{request: request} = event, :delete_record, _context)
      when is_map(request) do
    %{event | response: RecordMaterializer.delete(request)}
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
