defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A pure struct — it never dispatches. A record may travel between nodes
  **unmaterialized**: full metadata with `content: nil` and a signed
  `materialization_handle` that can be redeemed by `Zaq.Materialization`.
  """

  # What may leave the struct as JSON. `raw` is deliberately absent because it holds
  # provider internals. `materialization_handle` is signed and JSON-safe.
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
    :attributes,
    :materialization_handle
  ]

  @derive {Jason.Encoder, only: @public_fields}

  @enforce_keys [:id, :kind]
  @semantic_type :record
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
    :materialization_handle,
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
          materialization_handle: String.t() | nil
        }

  @doc """
  Returns the semantic Zoi type for canonical records.

  The JSON Schema representation is intentionally permissive because records can
  carry arbitrary provider payloads, while runtime validation still requires the
  canonical `%#{inspect(__MODULE__)}{}` struct.
  """
  @spec zoi_type(keyword()) :: Zoi.schema()
  def zoi_type(opts \\ []) do
    metadata =
      opts
      |> Keyword.get(:metadata, [])
      |> Keyword.put(:zaq_semantic_type, @semantic_type)

    opts
    |> Keyword.put(:metadata, metadata)
    |> Zoi.any()
    |> Zoi.refine({__MODULE__, :validate_zoi_type, []})
  end

  @doc "Returns the semantic schema marker used by agent-side Record processors."
  @spec semantic_type() :: :record
  def semantic_type, do: @semantic_type

  @doc "Returns the JSON-safe public metadata for a Record without materialized content."
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.take(@public_fields)
    |> Map.delete(:content)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), metadata_value(value)} end)
  end

  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(value), do: value

  @doc "Validates that a Zoi value is a canonical Record struct."
  @spec validate_zoi_type(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_zoi_type(%__MODULE__{}, _opts), do: :ok
  def validate_zoi_type(_value, _opts), do: {:error, "expected %#{inspect(__MODULE__)}{}"}
end
