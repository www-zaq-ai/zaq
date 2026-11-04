defmodule Zaq.System.RAGModelConfig do
  @moduledoc """
  Saved-only specialized RAG model selection. These settings do not enable runtime inference.
  Model eligibility uses catalog capabilities, never name matching.
  """
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :credential_id, :integer
    field :model, :string
  end

  def changeset(config, attrs) do
    changeset = cast(config, attrs, [:credential_id, :model])

    if get_field(changeset, :credential_id) || get_field(changeset, :model) do
      changeset
      |> validate_required([:credential_id, :model])
      |> validate_number(:credential_id, greater_than: 0)
    else
      changeset
    end
  end

  @doc "Whether catalog metadata explicitly supports the requested specialized purpose."
  def supports?(model, :reranking),
    do: get_in(model, [Access.key(:capabilities, %{}), :rerank]) == true

  def supports?(model, :decision) do
    output = get_in(model, [Access.key(:modalities, %{}), :output]) || []
    :decisions in output
  end
end
