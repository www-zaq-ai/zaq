defmodule Zaq.System.RetrievalConfig do
  @moduledoc "Validates knowledge-retrieval tuning independently of model configuration."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :max_cosine_distance, :float, default: 0.45
    field :fusion_bm25_weight, :float, default: 0.5
    field :fusion_vector_weight, :float, default: 0.5
  end

  @type t :: %__MODULE__{
          max_cosine_distance: float(),
          fusion_bm25_weight: float(),
          fusion_vector_weight: float()
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, attrs) do
    config
    |> cast(attrs, [:max_cosine_distance, :fusion_bm25_weight, :fusion_vector_weight],
      empty_values: []
    )
    |> validate_fields()
  end

  defp validate_fields(changeset) do
    changeset
    |> validate_required([:max_cosine_distance, :fusion_bm25_weight, :fusion_vector_weight])
    |> validate_number(:max_cosine_distance,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 2.0
    )
    |> validate_number(:fusion_bm25_weight,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:fusion_vector_weight,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_fusion_weight_sum()
  end

  defp validate_fusion_weight_sum(changeset) do
    bm25 = get_field(changeset, :fusion_bm25_weight)
    vector = get_field(changeset, :fusion_vector_weight)

    if is_float(bm25) and is_float(vector) and bm25 + vector < 0.1 do
      add_error(
        changeset,
        :fusion_bm25_weight,
        "combined fusion weights must sum to at least 0.1"
      )
    else
      changeset
    end
  end
end
