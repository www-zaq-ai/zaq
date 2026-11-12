defmodule Zaq.Ingestion.Api do
  @moduledoc """
  Ingestion role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Accounts.People
  alias Zaq.Event
  alias Zaq.Events.TrustedContext
  alias Zaq.Ingestion

  alias Zaq.Ingestion.Actions.{
    DeleteLabelDefinition,
    DeleteLabelDefinitions,
    EditResourceLabels,
    SaveLabelDefinition,
    UpdateLabelValues
  }

  alias Zaq.Ingestion.{
    ChunkLanguages,
    Document,
    DocumentProcessor,
    KnowledgeChunks,
    Labels,
    ResourceQuery
  }

  alias Zaq.InternalBoundaries
  alias Zaq.Permissions

  @impl true
  def handle_event(event, action, context), do: dispatch_event(action, event, context)

  defp dispatch_event(:query_resources, %Event{} = event, _context) do
    # Query parameters and actor fields cannot opt into a permission bypass.
    context = %{
      actor: event.actor,
      person_id: Keyword.get(event.opts, :person_id),
      team_ids: Keyword.get(event.opts, :team_ids),
      skip_permissions: Keyword.get(event.opts, :skip_permissions) == true
    }

    %{event | response: ResourceQuery.run(event.request, context)}
  end

  # Matching the action first avoids excessive Elixir 1.20 type-inference memory
  # across the overlapping event/request patterns below.
  defp dispatch_event(action, %Event{request: request} = event, _context)
       when action in [
              :save_label_definition,
              :edit_resource_labels,
              :update_label_values,
              :delete_label_definition,
              :delete_label_definitions
            ] do
    module =
      case action do
        :save_label_definition -> SaveLabelDefinition
        :edit_resource_labels -> EditResourceLabels
        :update_label_values -> UpdateLabelValues
        :delete_label_definition -> DeleteLabelDefinition
        :delete_label_definitions -> DeleteLabelDefinitions
      end

    response =
      case Jido.Exec.run(module, request, %{actor: event.actor, opts: event.opts}) do
        {:ok, %{result: result}} -> result
        {:error, _} = error -> error
      end

    %{event | response: response}
  end

  defp dispatch_event(:list_labels, %Event{} = event, _context) do
    %{
      event
      | response:
          Labels.list(
            event.actor,
            Map.get(event.request, :offset, 0),
            Map.get(event.request, :query, "")
          )
    }
  end

  defp dispatch_event(
         :get_resource_labels,
         %Event{request: %{resource: resource}} = event,
         _context
       ) do
    %{event | response: Labels.resource_editor(resource, event.actor, event.opts)}
  end

  defp dispatch_event(:label_value_summaries, %Event{request: %{ids: ids}} = event, _context) do
    %{event | response: Labels.value_summaries(ids, event.actor)}
  end

  defp dispatch_event(
         :label_values,
         %Event{request: %{label_id: id, query: query, offset: offset}} = event,
         _context
       ) do
    %{event | response: Labels.list_values(id, query, offset, event.actor)}
  end

  defp dispatch_event(
         :label_value_resources,
         %Event{request: %{label_id: id, value: value, offset: offset}} = event,
         _context
       ) do
    %{event | response: Labels.value_resources(id, value, offset, event.actor)}
  end

  defp dispatch_event(:label_deletion_preview, %Event{request: %{id: id}} = event, _context) do
    %{event | response: Labels.deletion_preview(id, event.actor)}
  end

  defp dispatch_event(:labels_deletion_preview, %Event{request: %{ids: ids}} = event, _context) do
    %{event | response: Labels.bulk_deletion_preview(ids, event.actor)}
  end

  defp dispatch_event(
         :label_value_suggestions,
         %Event{request: %{resource: resource, label_id: label_id, query: query}} = event,
         _context
       ) do
    %{event | response: Labels.value_suggestions(resource, label_id, query, event.actor)}
  end

  defp dispatch_event(
         :document_label_chips,
         %Event{request: %{sources: sources}} = event,
         _context
       ) do
    %{event | response: Labels.document_chips(sources, event.actor)}
  end

  defp dispatch_event(
         :ingest_records,
         %Event{request: %{records: records, params: params}} = event,
         _context
       )
       when is_list(records) and is_map(params) do
    %{event | response: Ingestion.ingest_records(records, put_actor(params, event.actor))}
  end

  defp dispatch_event(:process_data_source_changes, %Event{request: request} = event, _context)
       when is_map(request) do
    %{event | response: Ingestion.process_data_source_changes(request)}
  end

  defp dispatch_event(:enrich_records, %Event{request: %{records: records}} = event, _context)
       when is_list(records) do
    %{event | response: Ingestion.enrich_records(records)}
  end

  defp dispatch_event(:list_document_sources, %Event{request: %{query: query}} = event, _context)
       when is_binary(query) do
    ingestion_module = Keyword.get(event.opts, :ingestion_module, Ingestion)

    %{event | response: ingestion_module.list_document_sources(query)}
  end

  defp dispatch_event(:list_chunk_languages, %Event{} = event, _context) do
    inventory = Keyword.get(event.opts, :chunk_languages, ChunkLanguages)
    %{event | response: {:ok, inventory.list()}}
  end

  defp dispatch_event(
         :get_knowledge_base_chunks,
         %Event{request: %{chunk_ids: ids, access_opts: access_opts}} = event,
         _context
       )
       when is_list(access_opts) do
    %{event | response: KnowledgeChunks.fetch(ids, access_opts)}
  end

  defp dispatch_event(
         :fuse_knowledge_results,
         %Event{request: %{keyword_chunks: lexical, semantic_chunks: vector}} = event,
         _context
       )
       when is_list(lexical) and is_list(vector) do
    %{event | response: DocumentProcessor.fuse_chunks(lexical, vector)}
  end

  defp dispatch_event(
         :get_ingestion_details,
         %Event{request: %{source: source}, actor: actor} = event,
         _context
       )
       when is_binary(source) and is_map(actor) do
    response =
      case Document.get_by_source(source) do
        %Document{content: content} = document when is_binary(content) ->
          person = actor[:person_id] && People.get_person(actor[:person_id])

          if not is_nil(actor[:user_id]) and
               Permissions.can?(person, :read, document,
                 skip_permissions: actor[:skip_permissions] == true
               ) do
            {:ok, %{content: content, summary: get_in(document.metadata || %{}, ["ingestion"])}}
          else
            {:error, :unauthorized}
          end

        _ ->
          {:error, :not_found}
      end

    %{event | response: response}
  end

  defp dispatch_event(
         :limit_knowledge_results,
         %Event{
           request: %{chunks: chunks, max_total_results: maximum, token_budget: token_budget}
         } = event,
         _context
       )
       when is_list(chunks) do
    processor = Keyword.get(event.opts, :document_processor, DocumentProcessor)

    response =
      case processor.limit_chunks(chunks, maximum, token_budget) do
        {:error, _} = error -> error
        limited when is_list(limited) -> {:ok, limited}
      end

    %{event | response: response}
  end

  defp dispatch_event(
         :search_knowledge_base,
         %Event{request: %{query: query, access_opts: access_opts}} = event,
         _context
       )
       when is_binary(query) and is_list(access_opts) do
    processor = Keyword.get(event.opts, :document_processor, DocumentProcessor)
    %{event | response: processor.query_extraction(query, access_opts)}
  end

  defp dispatch_event(
         :sync_data_source_permission_projection,
         %Event{
           request: %{
             provider: provider,
             config_id: config_id,
             affected_file_ids: affected_file_ids
           }
         } = event,
         _context
       )
       when is_list(affected_file_ids) do
    ingestion_module = Keyword.get(event.opts, :ingestion_module, Ingestion)

    # Channels sets this server-owned option only after a completed source
    # mutation. Request fields cannot authorize cached source-grant invalidation.
    sync_context =
      event
      |> TrustedContext.from_event()
      |> Map.from_struct()
      |> Map.put(
        :source_acl_mutation_committed,
        Keyword.get(event.opts, :source_acl_mutation_committed) == true
      )

    %{
      event
      | response:
          ingestion_module.sync_data_source_permission_projection(
            provider,
            config_id,
            affected_file_ids,
            sync_context
          )
    }
  end

  defp dispatch_event(action, %Event{} = event, _context),
    do: InternalBoundaries.default_handle_event(event, action)

  defp put_actor(params, actor) when is_map(actor), do: Map.put(params, :actor, actor)
  defp put_actor(params, _actor), do: params
end
