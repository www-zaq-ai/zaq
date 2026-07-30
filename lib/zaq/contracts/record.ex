defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A record is a **handle**: identity and metadata, small enough to move between nodes freely.
  `:content` is filled only when someone materializes it — see `Zaq.Records.Materializer` and
  the `:materialization` descriptor below.
  """

  # `:materialization` and `:raw` are deliberately absent from this list.
  #
  # Both carry storage internals — locators, bucket keys, adapter ids, provider payloads —
  # and anything encoded here can end up in a tool result, where a model can read it and
  # fabricate one back. Excluding them is what lets a descriptor cross a node boundary as an
  # Erlang term while staying invisible to models. Adding either key here is a security
  # regression; `Zaq.Contracts.MaterializationTest` asserts against it.
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
    :materialization,
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
          materialization: Zaq.Contracts.Materialization.t() | nil,
          raw: map()
        }
end
