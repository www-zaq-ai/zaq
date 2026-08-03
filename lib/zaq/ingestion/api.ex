defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.Ingestion
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

  # -- records --

  def handle_event(%Event{request: %{file_ids: file_ids}} = event, :describe_records, _context)
      when is_list(file_ids) do
    %{event | response: Ingestion.describe_records(file_ids)}
  end

  def handle_event(%Event{request: %{params: params}} = event, :list_records, _context)
      when is_map(params) do
    %{event | response: Ingestion.list_records(params)}
  end

  def handle_event(
        %Event{request: %{file_id: file_id} = request} = event,
        :materialize_record,
        _context
      )
      when is_binary(file_id) do
    %{event | response: Ingestion.materialize_record(request)}
  end

  def handle_event(%Event{request: request} = event, :persist_record, _context)
      when is_map(request) do
    %{event | response: Ingestion.persist_record(request)}
  end

  def handle_event(%Event{request: request} = event, :update_record, _context)
      when is_map(request) do
    %{event | response: Ingestion.update_record(request)}
  end

  def handle_event(%Event{request: %{file_id: file_id}} = event, :delete_record, _context)
      when is_binary(file_id) do
    %{event | response: Ingestion.delete_record(file_id)}
  end

  def handle_event(
        %Event{request: %{file_id: file_id}} = event,
        :list_record_permissions,
        _context
      )
      when is_binary(file_id) do
    %{event | response: Ingestion.list_record_permissions(file_id)}
  end

  # -- volumes --

  def handle_event(%Event{request: %{params: params}} = event, :search_records, _context)
      when is_map(params) do
    %{event | response: Ingestion.search_records(params)}
  end

  def handle_event(%Event{request: request} = event, :volume_stats, _context)
      when is_map(request) do
    %{event | response: Ingestion.volume_stats()}
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
