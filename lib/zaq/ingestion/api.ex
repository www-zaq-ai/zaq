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

  def handle_event(
        %Event{request: %{provider: provider, params: params}} = event,
        :sync_data_source_permissions,
        _context
      )
      when is_map(params) do
    %{
      event
      | response: Ingestion.sync_data_source_permissions(provider, params, %{actor: event.actor})
    }
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)

  defp put_actor(params, actor) when is_map(actor), do: Map.put(params, :actor, actor)
  defp put_actor(params, _actor), do: params
end
