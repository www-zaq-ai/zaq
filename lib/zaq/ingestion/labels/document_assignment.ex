defmodule Zaq.Ingestion.Labels.DocumentAssignment do
  @moduledoc "Manual category inclusion/exclusion with a foreign key to its resource."
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]
  alias Zaq.Ingestion.Labels.AssignmentValue

  schema "document_label_assignments" do
    belongs_to :label, Zaq.Ingestion.Labels.Label
    belongs_to :document, Zaq.Ingestion.Document
    field :value, :string
    field :selected, :boolean
    field :origin, Ecto.Enum, values: [:manual], default: :manual
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds the selected-label projection for document IDs already authorized by the caller."
  def selected_labels_query(document_ids) do
    from a in __MODULE__,
      join: l in assoc(a, :label),
      where: a.document_id in ^document_ids and a.selected,
      order_by: [l.normalized_name, l.id],
      select: {a.document_id, %{id: l.id, name: l.name, value: a.value}}
  end

  @doc "Sets a manual decision with server-owned identity and provenance."
  def decision_changeset(assignment, selected, value \\ :unchanged) do
    assignment
    |> change(selected: selected, origin: :manual)
    |> AssignmentValue.put(selected, value)
    |> validate_required([:selected, :label_id, :document_id])
    |> unique_constraint([:document_id, :label_id])
    |> foreign_key_constraint(:label_id)
    |> foreign_key_constraint(:document_id)
  end
end
