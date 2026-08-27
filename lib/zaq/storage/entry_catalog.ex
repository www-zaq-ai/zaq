defmodule Zaq.Storage.EntryCatalog do
  @moduledoc """
  Stable identities for files and folders discovered on mounted Storage volumes.

  The catalog is Storage-owned. Paths and names can change, but ZAQ-managed
  renames update the catalog row so callers keep the same stable record id.
  External moves are treated as delete/create because the filesystem path is the
  only portable identity available across all supported mounts.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Repo
  alias Zaq.Storage.SourcePath

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "storage_entries" do
    field :volume, :string
    field :relative_path, :string
    field :kind, :string
    field :deleted_at, :utc_datetime

    belongs_to :parent, __MODULE__

    timestamps(type: :utc_datetime)
  end

  @required ~w(volume relative_path kind)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ [:parent_id, :deleted_at])
    |> validate_required(@required)
    |> validate_inclusion(:kind, ["file", "directory"])
    |> unique_constraint([:volume, :relative_path], name: :storage_entries_active_path_index)
  end

  @doc "Returns or creates the stable identity for the given live storage path."
  def ensure(volume, relative_path, kind) when is_binary(volume) and is_binary(relative_path) do
    normalized = normalize(relative_path)

    case get_active(volume, normalized) do
      %__MODULE__{} = entry -> {:ok, entry}
      nil -> insert_entry(volume, normalized, kind)
    end
  end

  def get_active(volume, relative_path) when is_binary(volume) and is_binary(relative_path) do
    path = normalize(relative_path)

    Repo.one(
      from(e in __MODULE__,
        where: e.volume == ^volume and e.relative_path == ^path and is_nil(e.deleted_at)
      )
    )
  end

  def by_id(id) when is_binary(id) do
    Repo.one(from(e in __MODULE__, where: e.id == ^id and is_nil(e.deleted_at)))
  end

  @doc "Returns active ancestors from nearest parent to root."
  def ancestors(id) when is_binary(id) do
    id
    |> by_id()
    |> do_ancestors([])
  end

  @doc "Returns active descendants for an entry, excluding the entry itself."
  def descendants(id) when is_binary(id) do
    case by_id(id) do
      nil -> []
      entry -> descendants_for(entry)
    end
  end

  def rename(volume, old_relative_path, new_relative_path) do
    old_relative_path = normalize(old_relative_path)
    new_relative_path = normalize(new_relative_path)

    with %__MODULE__{} = entry <- get_active(volume, old_relative_path) || {:error, :not_found},
         {:ok, parent_id} <- parent_id(volume, new_relative_path) do
      entry
      |> changeset(%{relative_path: new_relative_path, parent_id: parent_id})
      |> Repo.update()
    end
  end

  def tombstone(volume, relative_path) do
    prefix = normalize(relative_path)
    now = DateTime.utc_now(:second)

    from(e in __MODULE__,
      where:
        e.volume == ^volume and is_nil(e.deleted_at) and
          (e.relative_path == ^prefix or like(e.relative_path, ^"#{prefix}/%"))
    )
    |> Repo.update_all(set: [deleted_at: now, updated_at: now])

    :ok
  end

  defp insert_entry(volume, relative_path, kind) do
    with {:ok, parent_id} <- parent_id(volume, relative_path) do
      %__MODULE__{}
      |> changeset(%{
        volume: volume,
        relative_path: relative_path,
        kind: to_string(kind),
        parent_id: parent_id
      })
      |> Repo.insert()
      |> case do
        {:ok, entry} -> {:ok, entry}
        {:error, %{errors: [volume: _]}} -> {:ok, get_active(volume, relative_path)}
        {:error, %{errors: [relative_path: _]}} -> {:ok, get_active(volume, relative_path)}
        error -> error
      end
    end
  end

  defp parent_id(_volume, "."), do: {:ok, nil}
  defp parent_id(_volume, ""), do: {:ok, nil}

  defp parent_id(volume, relative_path) do
    parent_path = relative_path |> Path.dirname() |> normalize()

    if parent_path == relative_path do
      {:ok, nil}
    else
      with {:ok, parent} <- ensure(volume, parent_path, :directory) do
        {:ok, parent.id}
      end
    end
  end

  defp do_ancestors(nil, acc), do: acc
  defp do_ancestors(%__MODULE__{parent_id: nil}, acc), do: acc

  defp do_ancestors(%__MODULE__{parent_id: parent_id}, acc) do
    parent = by_id(parent_id)
    do_ancestors(parent, acc ++ List.wrap(parent))
  end

  defp descendants_for(%__MODULE__{volume: volume, relative_path: path}) do
    prefix = normalize(path)

    from(e in __MODULE__,
      where:
        e.volume == ^volume and is_nil(e.deleted_at) and
          e.relative_path != ^prefix and like(e.relative_path, ^"#{prefix}/%")
    )
    |> Repo.all()
  end

  defp normalize(nil), do: "."
  defp normalize(""), do: "."
  defp normalize(path), do: SourcePath.normalize_relative(path)
end
