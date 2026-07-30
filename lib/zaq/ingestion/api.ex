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

  # Skill resource bundles. Callers address a bundle by its opaque locator and never name a
  # volume — resolving one is this role's job. Any extra key in the request (`:volume`, say)
  # is ignored by construction, since only `:bundle` and `:resource` are matched.
  def handle_event(%Event{request: %{bundle: locator}} = event, :list_skill_bundle, _context)
      when is_binary(locator) do
    %{event | response: Ingestion.list_skill_bundle(locator)}
  end

  def handle_event(
        %Event{request: %{bundle: locator, resource: resource_path}} = event,
        :read_skill_bundle_resource,
        _context
      )
      when is_binary(locator) and is_binary(resource_path) do
    %{event | response: Ingestion.read_skill_bundle_resource(locator, resource_path)}
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
