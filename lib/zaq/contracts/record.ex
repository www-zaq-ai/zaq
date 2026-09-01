defmodule Zaq.Contracts.Record do
  @moduledoc """
  Canonical domain-agnostic record payload.

  A pure struct — it never dispatches. A record may travel between nodes
  **unmaterialized**: full metadata with `content: nil` and a signed
  `materialization_handle` that can be redeemed by `Zaq.Materialization`.
  """

  # What may leave the struct as JSON. `raw` is deliberately absent because it holds
  # provider internals. Signed handles/tokens are JSON-safe.
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
    :materialization_handle,
    :provenance_ref
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
    :provenance_ref,
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
          materialization_handle: String.t() | nil,
          provenance_ref: String.t() | nil
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
    |> Zoi.transform({__MODULE__, :zoi_record_from_map, []})
    |> Zoi.refine({__MODULE__, :validate_zoi_type, []})
  end

  @doc false
  def zoi_record_from_map(%__MODULE__{} = record, _opts), do: {:ok, record}

  def zoi_record_from_map(%{} = map, _opts) do
    case from_map(map) do
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, "invalid Record provenance: #{inspect(reason)}"}
    end
  end

  def zoi_record_from_map(value, _opts), do: {:ok, value}

  @doc "Returns the semantic schema marker used by agent-side Record processors."
  @spec semantic_type() :: :record
  def semantic_type, do: @semantic_type

  @doc "Rebuilds and verifies a Record from its JSON-safe public projection."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{} = map) do
    with {:ok, record} <- build_from_map(map),
         {:ok, _claims} <- __MODULE__.Provenance.verify(record) do
      {:ok, record}
    end
  end

  def from_map(_map), do: {:error, :invalid_record}

  defp build_from_map(%{} = map) do
    with id when is_binary(id) <- public_value(map, "id"),
         kind when not is_nil(kind) <- public_value(map, "kind"),
         {:ok, permissions} <- public_permissions(public_value(map, "permissions")) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: normalize_kind(kind),
         content: public_value(map, "content"),
         name: public_value(map, "name"),
         parent_id: public_value(map, "parent_id"),
         parent_ids: public_value(map, "parent_ids") || [],
         mime_type: public_value(map, "mime_type"),
         path: public_value(map, "path"),
         url: public_value(map, "url"),
         size: public_value(map, "size"),
         description: public_value(map, "description"),
         icon: public_value(map, "icon"),
         created_at: public_value(map, "created_at"),
         modified_at: public_value(map, "modified_at"),
         change_type: normalize_existing_atom(public_value(map, "change_type")),
         lifecycle_state: normalize_existing_atom(public_value(map, "lifecycle_state")),
         deleted_at: public_value(map, "deleted_at"),
         permissions: permissions,
         owners: public_value(map, "owners") || [],
         attributes: public_value(map, "attributes") || %{},
         materialization_handle: public_value(map, "materialization_handle"),
         provenance_ref: public_value(map, "provenance_ref")
       }}
    else
      _ -> {:error, :invalid_record}
    end
  end

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
  defp metadata_value(%__MODULE__{} = value), do: metadata(value)
  defp metadata_value(value) when is_list(value), do: Enum.map(value, &metadata_value/1)
  defp metadata_value(value), do: value

  defp public_permissions(nil), do: {:ok, nil}

  defp public_permissions(permissions) when is_list(permissions) do
    permissions
    |> Enum.reduce_while({:ok, []}, fn permission, {:ok, acc} ->
      case from_map(permission) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp public_permissions(_permissions), do: {:error, :invalid_record}

  defp public_value(map, key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, String.to_existing_atom(key))
    end
  end

  defp normalize_kind("file"), do: :file
  defp normalize_kind("folder"), do: :folder
  defp normalize_kind("permission"), do: :permission
  defp normalize_kind("spreadsheet"), do: :spreadsheet
  defp normalize_kind(kind), do: normalize_existing_atom(kind)

  defp normalize_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_existing_atom(value), do: value

  @doc "Validates that a Zoi value is a canonical Record struct."
  @spec validate_zoi_type(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_zoi_type(%__MODULE__{} = record, _opts) do
    case __MODULE__.Provenance.verify(record) do
      {:ok, _claims} -> :ok
      {:error, reason} -> {:error, "invalid Record provenance: #{inspect(reason)}"}
    end
  end

  def validate_zoi_type(_value, _opts), do: {:error, "expected %#{inspect(__MODULE__)}{}"}
end
