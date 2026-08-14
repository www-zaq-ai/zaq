defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A pure struct — it never dispatches. A record may travel between nodes
  **unmaterialized**: full metadata with `content: nil` and a `materializing_event` that
  fetches the bytes. Whoever wants the content dispatches that event itself.

  `materializing_event` is excluded from the `Jason.Encoder` `only:` list, because a
  dispatchable event inside a serialized payload would let whoever holds the record choose
  which event fires, on which node, with which params. As a result a record rebuilt from
  JSON — out of an LLM tool result or persisted workflow state — always comes back with
  `materializing_event: nil` and cannot be materialized.
  """

  # What may leave the struct as JSON. `raw` and `materializing_event` are deliberately
  # absent — `raw` holds provider internals, and `materializing_event` is a dispatchable
  # capability that must never travel to a model or into persisted state.
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
end
