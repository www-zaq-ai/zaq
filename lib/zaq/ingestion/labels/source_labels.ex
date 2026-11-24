defmodule Zaq.Ingestion.Labels.SourceLabels do
  @moduledoc """
  Source-authorized label editing before or after content ingestion.

  Channels owns current source metadata, canonical identity and permissions. Open
  resolves that context without writes. Save resolves update authority again and
  composes identity insertion, checked source ACL projection and the existing
  versioned document editor in one transaction. It never materializes content or
  schedules ingestion. Source contexts stay inside this orchestration and the
  authenticated resource projection; clients receive only the canonical selector.
  """
  import Ecto.Query

  alias Zaq.Channels.Events, as: ChannelEvents
  alias Zaq.Contracts.SourceRecordContext
  alias Zaq.Ingestion.{Document, ExternalPermissions, ExternalSource}
  alias Zaq.Ingestion.Labels.{Access, ResourceLabels}
  alias Zaq.Repo

  @spec editor(map(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def editor(resource, actor, opts \\ []) do
    with {:ok, user} <- Access.user(actor),
         {:ok, context} <- source_context(resource, :read, actor, user, opts),
         :ok <- file_context(context),
         {:ok, projection} <-
           ResourceLabels.editor(%{type: "document"}, actor, source_context: context) do
      editable? = match?({:ok, _}, source_context(resource, :update, actor, user, opts))
      {:ok, source_projection(projection, context, editable?)}
    end
  end

  @spec edit(map(), list(), map() | nil, keyword()) :: {:ok, map() | :ok} | {:error, term()}
  def edit(resource, edits, actor, opts \\ []) do
    with {:ok, user} <- Access.user(actor),
         {:ok, context} <- source_context(resource, :update, actor, user, opts),
         :ok <- file_context(context) do
      Repo.transaction(fn ->
        document = ensure_document!(context)
        apply_source_permissions!(context, document)

        %{type: "document", id: document.id}
        |> ResourceLabels.edit(edits, actor,
          source_context: context,
          return_projection: Keyword.get(opts, :return_projection, true)
        )
        |> unwrap!()
        |> source_projection(context, true)
      end)
    end
  end

  defp source_context(%{source_ref: reference}, right, actor, user, opts) do
    actor = Map.drop(actor, [:skip_permissions, "skip_permissions"])

    ChannelEvents.build_and_dispatch_data_source_record_context_event(reference, right,
      actor: actor,
      node_router: Keyword.get(opts, :node_router, Zaq.NodeRouter),
      event_opts: [skip_permissions: user.role.name == "super_admin"]
    ).response
  end

  defp source_context(_, _, _, _, _), do: {:error, :invalid_resource}

  defp file_context(%SourceRecordContext{record: %{kind: :file}}), do: :ok
  defp file_context(%SourceRecordContext{}), do: {:error, :unsupported_resource_kind}

  defp ensure_document!(context) do
    source = ExternalSource.source(context.record)

    document =
      Document.insert_new(%{
        source: source,
        title: context.record.name,
        metadata: ExternalSource.metadata(context.record)
      })
      |> unwrap!()

    Repo.one(
      from d in Document, where: d.id == ^document.id and d.source == ^source, lock: "FOR UPDATE"
    ) ||
      Repo.rollback(:not_found)
  end

  defp apply_source_permissions!(context, document) do
    case ExternalPermissions.apply(context.record, [document]) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp source_projection(:ok, _context, _editable?), do: :ok

  defp source_projection(projection, context, editable?) do
    projection
    |> Map.put(:document_id, projection.resource.id)
    |> Map.put(:source_kind, context.record.kind)
    |> Map.put(:resource, %{type: "source", source_ref: context.reference})
    |> Map.put(:editable?, editable?)
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
end
