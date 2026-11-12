defmodule Zaq.Ingestion.Labels.Label do
  @moduledoc "A typed label definition; assignment configuration belongs to the definition."
  use Ecto.Schema
  import Ecto.Changeset
  alias Zaq.Ingestion.Labels.AssignmentValue

  schema "labels" do
    field :name, :string
    field :description, :string, default: ""
    field :normalized_name, :string
    field :value_type, :string, default: "boolean"
    field :value_config, :map, default: %{}
    field :resources, {:array, :string}, default: ["document", "chunk"]
    field :assignment_type, :string, default: "manual"
    field :threshold, :integer, default: 80
    field :lock_version, :integer, default: 1
    field :targets, {:array, :map}, virtual: true, default: []
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates category text and derives its case-insensitive unique name."
  def changeset(label, attrs) do
    label
    |> cast(attrs, [
      :name,
      :description,
      :value_type,
      :value_config,
      :resources,
      :assignment_type,
      :threshold
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 80)
    |> validate_length(:description, max: 4_000)
    |> normalize_description()
    |> normalize_name()
    |> validate_required([:value_type, :value_config, :resources, :assignment_type, :threshold])
    |> validate_inclusion(:value_type, ["boolean", "scale", "options"])
    |> validate_inclusion(:assignment_type, ["manual", "automatic"])
    |> validate_number(:threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_resources()
    |> validate_config()
    |> unique_constraint(:name, name: :labels_normalized_name_index)
  end

  @doc "Projects the resource list for catalog consumers during the typed editor migration."
  def with_targets(label),
    do: %{
      label
      | targets:
          Enum.map(
            label.resources,
            &%{resource_type: &1, automatic: label.assignment_type == "automatic"}
          )
    }

  defp validate_resources(changeset) do
    resources = get_field(changeset, :resources)

    if is_list(resources) and resources != [] and
         Enum.all?(resources, &(&1 in ["document", "chunk"])) and
         Enum.uniq(resources) == resources,
       do: changeset,
       else: add_error(changeset, :resources, "must contain distinct document or chunk resources")
  end

  defp validate_config(changeset) do
    config = get_field(changeset, :value_config)
    type = get_field(changeset, :value_type)

    if valid_config?(type, config),
      do: changeset,
      else: add_error(changeset, :value_config, "must define a valid #{type} value")
  end

  defp valid_config?("boolean", config), do: config == %{}

  defp valid_config?(
         "scale",
         %{"min" => minimum, "max" => maximum, "increment" => increment} = config
       ) do
    map_size(config) == 3 and Enum.all?([minimum, maximum, increment], &is_number/1) and
      minimum < maximum and increment > 0 and
      AssignmentValue.valid_for?(
        %{value_type: "scale", value_config: config},
        maximum
      )
  end

  defp valid_config?("options", %{"options" => options} = config) when is_list(options) do
    map_size(config) == 1 and options != [] and
      Enum.all?(options, &valid_option?/1) and
      length(Enum.uniq_by(options, & &1["id"])) == length(options)
  end

  defp valid_config?(_, _), do: false

  defp valid_option?(%{"id" => id, "label" => label} = option) do
    map_size(option) == 2 and is_binary(id) and is_binary(label) and String.valid?(id) and
      String.valid?(label) and String.length(id) in 1..80 and String.trim(id) == id and
      String.length(String.trim(label)) in 1..200
  end

  defp valid_option?(_), do: false

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
