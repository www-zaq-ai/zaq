defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A record may travel between nodes **unmaterialized**: full metadata, `content: nil`. The
  bytes are fetched only when a service actually needs them, by dispatching
  `materializing_event` — see `Zaq.Contracts.Record.Materializer`, which owns that decision.
  This module stays a pure struct; it never dispatches.

  `materializing_event` is deliberately absent from the `Jason.Encoder` `only:` list. A
  dispatchable event carried inside a data payload is a confused-deputy risk: whoever holds
  the record would otherwise control which event fires, on which node, with which params.
  Excluding it means the field cannot survive a round trip through an LLM tool result or
  persisted workflow state, so a record rebuilt from JSON can never carry an attacker-chosen
  event. `Materializer` re-checks against a whitelist regardless.
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
  The fields that may leave a record — the same list the `Jason.Encoder` derives from.
  """
  @spec public_fields() :: [atom()]
  def public_fields, do: @public_fields

  @doc """
  The record as a plain map carrying only its public fields.

  For boundaries that need a map rather than a struct — an agent tool's output, say, where
  the value is validated against a schema and then serialized for a model. Going through
  `public_fields/0` rather than `Map.from_struct/1` is what keeps `raw` and
  `materializing_event` from leaking by that route.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = record), do: Map.take(record, @public_fields)
end
