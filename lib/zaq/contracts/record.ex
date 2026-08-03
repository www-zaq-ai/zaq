defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A pure struct — it never dispatches. A record may travel between nodes
  **unmaterialized**: full metadata with `content: nil` and a `materializing_event` that
  fetches the bytes. Dispatching that event is `Zaq.Contracts.Record.Materializer`'s job.

  `materializing_event` is excluded from both the `Jason.Encoder` `only:` list and
  `to_map/1`, because a dispatchable event inside a serialized payload would let whoever
  holds the record choose which event fires, on which node, with which params. As a result a
  record rebuilt from JSON — out of an LLM tool result or persisted workflow state — always
  comes back with `materializing_event: nil` and cannot be materialized.
  """

  # The record's public projection: what may leave the struct, whether as JSON or as a plain
  # map. `raw` and `materializing_event` are deliberately absent — `raw` holds provider
  # internals, and `materializing_event` is a dispatchable capability that must never travel
  # to a model or into persisted state.
  #
  # One list, used by both the encoder and `to_map/1`, so the two cannot drift apart and
  # accidentally expose a field through one path but not the other.
  @public_fields [
    :id,
    :kind,
    :content,
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

  @derive {Jason.Encoder, only: @public_fields}

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    :content,
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
    :materializing_event,
    parent_ids: [],
    owners: [],
    attributes: %{},
    raw: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :file | :folder | :permission | :spreadsheet | atom(),
          content: String.t() | [term()] | map() | nil,
          name: String.t() | nil,
          parent_id: String.t() | nil,
          parent_ids: [String.t()],
          mime_type: String.t() | nil,
          path: String.t() | nil,
          url: String.t() | nil,
          size: integer() | nil,
          description: String.t() | nil,
          owners: [map()],
          icon: map() | String.t() | nil,
          created_at: DateTime.t() | nil,
          modified_at: DateTime.t() | nil,
          change_type: :created | :updated | :deleted | nil,
          lifecycle_state: :active | :deleted | nil,
          deleted_at: DateTime.t() | nil,
          permissions: nil | [t()],
          attributes: map(),
          raw: map(),
          materializing_event: Zaq.Event.t() | nil
        }

  @doc """
  The record as a plain map carrying only the fields the `Jason.Encoder` derives from.

  For boundaries that need a map rather than a struct, such as an agent tool's output.
  Takes only the public fields rather than using `Map.from_struct/1`, so `raw` and
  `materializing_event` are dropped.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = record), do: Map.take(record, @public_fields)
end
