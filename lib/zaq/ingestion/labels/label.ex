defmodule Zaq.Ingestion.Labels.Label do
  @moduledoc "A named category with separately owned target settings and assignments."
  use Ecto.Schema
  import Ecto.Changeset

  schema "labels" do
    field :name, :string
    field :description, :string, default: ""
    field :normalized_name, :string
    field :lock_version, :integer, default: 1
    has_many :targets, Zaq.Ingestion.Labels.Target
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates category text and derives its case-insensitive unique name."
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 4_000)
    |> normalize_description()
    |> normalize_name()
    |> unique_constraint(:name, name: :labels_normalized_name_index)
  end

  defp normalize_description(changeset) do
    if is_nil(get_field(changeset, :description)),
      do: put_change(changeset, :description, ""),
      else: changeset
  end

  defp normalize_name(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) ->
        put_change(
          changeset,
          :normalized_name,
          name |> String.normalize(:nfc) |> String.downcase()
        )

      _ ->
        changeset
    end
  end
end
