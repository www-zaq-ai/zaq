defmodule Zaq.Contracts.Record do
  @moduledoc "Canonical domain-agnostic record payload."

  @derive {
    Jason.Encoder,
    only: [
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
  }

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
    parent_ids: [],
    owners: [],
    attributes: %{},
    raw: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
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
          raw: map()
        }
end
