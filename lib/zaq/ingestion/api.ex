defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
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
  # is ignored by construction, since only `:bundle` is matched.
  def handle_event(%Event{request: %{bundle: locator}} = event, :list_skill_bundle, _context)
      when is_binary(locator) do
    %{event | response: Ingestion.list_skill_bundle(locator)}
  end

  # Record materialization. The two verbs are separate clauses on purpose: writing is reachable
  # only through `:persist_record`, so a role that must not write simply does not carry that
  # clause. `Zaq.Ingestion.BundleContent` refuses any descriptor that is not a skill bundle, so
  # there is no generic "read a path" action here for a caller to reach for.
  #
  # A record with no descriptor does not match, and falls through to the default handler.
  def handle_event(
        %Event{request: %{record: %Record{materialization: %Materialization{}} = record}} = event,
        :materialize_record,
        _context
      ) do
    %{event | response: Ingestion.materialize_record(record)}
  end

  def handle_event(
        %Event{request: %{record: %Record{materialization: %Materialization{}} = record}} = event,
        :persist_record,
        _context
      ) do
    %{event | response: Ingestion.persist_record(record)}
  end

  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
