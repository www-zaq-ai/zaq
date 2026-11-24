defmodule Zaq.Ingestion.Labels.Assignment do
  @moduledoc """
  One versioned label decision for a resource, with typed value and explicit state.

  Resource IDs are canonical strings so source folders can share this store. Generated
  database columns retain document/chunk foreign keys without duplicating decisions.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Zaq.Ingestion.Labels.AssignmentValue

  schema "label_assignments" do
    belongs_to :label, Zaq.Ingestion.Labels.Label
    field :resource_type, :string
    field :resource_id, :string
    field :document_id, :integer
    field :chunk_id, :integer
    field :value, AssignmentValue
    field :state, Ecto.Enum, values: [:assigned, :pending, :excluded]
    field :origin, Ecto.Enum, values: [:manual, :automatic]
    field :metadata, :map, default: %{}
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the assigned/pending label projection for already authorized document IDs."
  def selected_labels_query(document_ids) do
    keys = Enum.map(document_ids, &to_string/1)

    from a in __MODULE__,
      join: l in assoc(a, :label),
      where:
        a.resource_type == "document" and a.resource_id in ^keys and
          a.state in [:assigned, :pending],
      order_by: [l.normalized_name, l.id],
      select:
        {a.document_id,
         %{
           id: l.id,
           name: l.name,
           value: a.value,
           state: a.state,
           value_type: l.value_type,
           value_config: l.value_config
         }}
  end

  @doc "Filters stored values by their definition's display text, using a literal substring."
  def search_values(query, nil), do: query

  def search_values(query, search) do
    from a in query,
      join: label in assoc(a, :label),
      where:
        fragment(
          """
          strpos(lower(coalesce(
            (SELECT option->>'label'
             FROM jsonb_array_elements(CASE WHEN ? = 'options' THEN ?->'options' ELSE '[]'::jsonb END) AS option
             WHERE option->>'id' = ?->>'value' LIMIT 1),
            ?->>'value', '')), lower(?)) > 0
          """,
          label.value_type,
          label.value_config,
          a.value,
          a.value,
          ^search
        )
  end

  @doc "Builds a server-owned decision; missing automatic values remain pending without evaluation."
  def decision_changeset(assignment, label, operation, value \\ :unchanged) do
    value = if(value == :unchanged, do: assignment.value, else: value)
    {state, origin, value} = decision(label, operation, value)

    assignment
    |> change(state: state, origin: origin, value: value)
    |> validate_required([:state, :origin, :label_id, :resource_type, :resource_id])
    |> validate_inclusion(:resource_type, ["document", "chunk"])
    |> validate_value(label)
    |> unique_constraint([:resource_type, :resource_id, :label_id])
    |> foreign_key_constraint(:label_id)
    |> foreign_key_constraint(:resource_id, name: :label_assignments_document_id_fkey)
    |> foreign_key_constraint(:resource_id, name: :label_assignments_chunk_id_fkey)
    |> check_constraint(:resource_id, name: :chunk_resource_available)
  end

  defp decision(_label, "remove", _value), do: {:excluded, :manual, nil}

  defp decision(%{assignment_type: "automatic"}, "reset_automatic", _value),
    do: {:pending, :automatic, nil}

  defp decision(%{assignment_type: "automatic"}, "add", nil), do: {:pending, :automatic, nil}
  defp decision(_label, _operation, value), do: {:assigned, :manual, value}

  defp validate_value(changeset, label) do
    if get_field(changeset, :state) == :assigned and
         not AssignmentValue.valid_for?(label, get_field(changeset, :value)),
       do: add_error(changeset, :value, "must match the label definition"),
       else: changeset
  end
end
