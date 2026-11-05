defmodule Zaq.Ingestion.Labels.Target do
  @moduledoc "Supported resource type for a category; automatic settings are disabled in PR 1."
  use Ecto.Schema
  import Ecto.Changeset

  schema "label_targets" do
    belongs_to :label, Zaq.Ingestion.Labels.Label
    field :resource_type, :string
    field :automatic, :boolean, default: false
  end

  @doc "Builds a target after category validation."
  def changeset(target, type) do
    target
    |> change(resource_type: type, automatic: false)
    |> validate_inclusion(:resource_type, ["document", "chunk"])
    |> unique_constraint([:label_id, :resource_type])
    |> foreign_key_constraint(:label_id)
  end
end
