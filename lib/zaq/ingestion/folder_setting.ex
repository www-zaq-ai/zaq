defmodule Zaq.Ingestion.FolderSetting do
  @moduledoc """
  Persists per-folder tag settings (e.g. `"public"`) across re-ingests.

  A single row identifies a (volume_name, folder_path) pair and stores an
  array of tag strings that apply to all documents under that path.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Repo

  schema "folder_settings" do
    field :volume_name, :string
    field :folder_path, :string
    field :tags, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(volume_name folder_path)a
  @optional_fields ~w(tags)a

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint([:volume_name, :folder_path],
      name: :folder_settings_volume_name_folder_path_index
    )
  end

  @doc "Upserts a folder setting by (volume_name, folder_path)."
  def upsert(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:tags, :updated_at]},
      conflict_target: [:volume_name, :folder_path],
      returning: true
    )
  end

  @doc "Returns the folder setting for the given volume and path, or nil."
  def get(volume_name, folder_path) do
    Repo.get_by(__MODULE__, volume_name: volume_name, folder_path: folder_path)
  end
end
