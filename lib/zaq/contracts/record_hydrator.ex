defmodule Zaq.Contracts.RecordHydrator do
  @moduledoc """
  Rebuilds runtime materialization capabilities for persisted records.

  Persisted record metadata describes the semantic source of a record, but it never
  stores a node destination, action, or dispatchable event. This module maps trusted
  source types to owning roles and asks that role to build the current
  `materializing_event`.
  """

  alias Zaq.Contracts.{Record, RecordCapability}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @source_roles %{"communication_media" => :channels}
  @stored_fields [
    :id,
    :kind,
    :name,
    :parent_id,
    :mime_type,
    :path,
    :url,
    :size,
    :description,
    :icon,
    :created_at,
    :modified_at,
    :change_type,
    :lifecycle_state,
    :deleted_at,
    :permissions,
    :parent_ids,
    :owners,
    :attributes
  ]
  @record_kinds %{
    "file" => :file,
    "folder" => :folder,
    "permission" => :permission,
    "spreadsheet" => :spreadsheet
  }

  @doc "Reconstructs a record and asks its owning role for a current materialization event."
  @spec hydrate(Record.t() | map(), map()) :: {:ok, Record.t()} | {:error, term()}
  def hydrate(record_or_attrs, context \\ %{}) when is_map(context) do
    with {:ok, record} <- to_record(record_or_attrs) do
      hydrate_record(record, context)
    end
  end

  defp hydrate_record(%Record{content: content} = record, _context) when not is_nil(content),
    do: {:ok, record}

  defp hydrate_record(%Record{materializing_event: %Event{}} = record, _context),
    do: {:ok, record}

  defp hydrate_record(%Record{} = record, context) do
    with {:ok, destination} <- destination(record),
         :ok <- verify_capability(record, context),
         {:ok, %Event{} = materializing_event} <- dispatch_hydration(record, destination, context) do
      {:ok, %{record | materializing_event: materializing_event}}
    end
  end

  defp to_record(%Record{} = record), do: {:ok, record}

  defp to_record(attrs) when is_map(attrs) do
    with {:ok, id} <- required_binary(attrs, :id),
         {:ok, kind} <- record_kind(value(attrs, :kind)) do
      record_attrs =
        Enum.reduce(@stored_fields, %{id: id, kind: kind}, &put_stored_field(&2, attrs, &1))

      {:ok, struct(Record, record_attrs)}
    end
  end

  defp to_record(_), do: {:error, {:invalid_record, :not_a_map}}

  defp put_stored_field(record_attrs, _attrs, field) when field in [:id, :kind],
    do: record_attrs

  defp put_stored_field(record_attrs, attrs, field) do
    case value(attrs, field) do
      nil -> record_attrs
      field_value -> Map.put(record_attrs, field, field_value)
    end
  end

  defp destination(%Record{attributes: attributes}) when is_map(attributes) do
    source_type = Map.get(attributes, "source_type") || Map.get(attributes, :source_type)

    case Map.fetch(@source_roles, source_type) do
      {:ok, destination} -> {:ok, destination}
      :error -> {:error, {:unsupported_source_type, source_type}}
    end
  end

  defp destination(%Record{}), do: {:error, {:unsupported_source_type, nil}}

  defp verify_capability(%Record{attributes: attributes} = record, context)
       when is_map(attributes) do
    case Map.get(attributes, "source_type") || Map.get(attributes, :source_type) do
      "communication_media" -> RecordCapability.authorize(record, context)
      _ -> :ok
    end
  end

  defp verify_capability(%Record{}, _context), do: :ok

  defp dispatch_hydration(record, destination, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    event =
      Event.new(record, destination,
        actor: Map.get(context, :actor),
        opts: [action: :hydrate_record]
      )

    case node_router.dispatch(event) do
      %Event{response: {:ok, %Event{} = materializing_event}} ->
        {:ok, materializing_event}

      %Event{response: {:error, reason}} ->
        {:error, reason}

      %Event{response: response} ->
        {:error, {:unexpected_hydration_response, response}}

      response ->
        {:error, {:unexpected_hydration_response, response}}
    end
  end

  defp required_binary(attrs, field) do
    case value(attrs, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, {:invalid_record, :missing_id}}
      _ -> {:error, {:invalid_record, :invalid_id}}
    end
  end

  defp record_kind(kind)
       when is_atom(kind) and kind in [:file, :folder, :permission, :spreadsheet],
       do: {:ok, kind}

  defp record_kind(kind) when is_binary(kind) do
    case Map.fetch(@record_kinds, kind) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_record, {:unsupported_kind, kind}}}
    end
  end

  defp record_kind(kind), do: {:error, {:invalid_record, {:unsupported_kind, kind}}}

  defp value(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(field))
    end
  end
end
