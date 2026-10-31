defmodule Zaq.System.OperationModelConfig do
  @moduledoc "Dedicated text-generation selections and sampling, independent of the global LLM."
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :credential_id, :integer
    field :model, :string
    field :temperature, :float, default: 0.0
    field :top_p, :float, default: 0.9
  end

  def changeset(config, attrs) do
    changeset = cast(config, attrs, [:credential_id, :model, :temperature, :top_p])

    changeset =
      if get_field(changeset, :credential_id) || get_field(changeset, :model) do
        changeset
        |> validate_required([:credential_id, :model])
        |> validate_number(:credential_id, greater_than: 0)
      else
        changeset
      end

    changeset
    |> validate_required([:temperature, :top_p])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:top_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
  end

  @doc "Text output is required; an unknown catalog entry is handled by custom-model selection."
  def supports?(model) do
    output = Map.get(Map.get(model, :modalities) || %{}, :output) || []
    :text in output
  end
end
