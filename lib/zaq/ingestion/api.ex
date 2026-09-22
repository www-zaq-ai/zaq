defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.Events.TrustedContext
  alias Zaq.Ingestion
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(
        %Event{request: %{records: records, params: params}} = event,
        :ingest_records,
        _context
      )
      when is_list(records) and is_map(params) do
    %{event | response: Ingestion.ingest_records(records, put_actor(params, event.actor))}
  end

  def handle_event(%Event{request: request} = event, :process_data_source_changes, _context)
      when is_map(request) do
    %{event | response: Ingestion.process_data_source_changes(request)}
  end

  def handle_event(%Event{request: %{records: records}} = event, :enrich_records, _context)
      when is_list(records) do
    %{event | response: Ingestion.enrich_records(records)}
  end

  def handle_event(%Event{request: %{query: query}} = event, :list_document_sources, _context)
      when is_binary(query) do
    ingestion_module = Keyword.get(event.opts, :ingestion_module, Ingestion)
    %{event | response: ingestion_module.list_document_sources(query)}
  end

  def handle_event(
        %Event{
          request: %{
            provider: provider,
            config_id: config_id,
            affected_file_ids: affected_file_ids
          }
        } = event,
        :sync_data_source_permission_projection,
        _context
      )
      when is_list(affected_file_ids) do
    ingestion_module = Keyword.get(event.opts, :ingestion_module, Ingestion)

    %{
      event
      | response:
          ingestion_module.sync_data_source_permission_projection(
            provider,
            config_id,
            affected_file_ids,
            TrustedContext.from_event(event)
          )
    }
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)

  defp put_actor(params, actor) when is_map(actor), do: Map.put(params, :actor, actor)
  defp put_actor(params, _actor), do: params
end
