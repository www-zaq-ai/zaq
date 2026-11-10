defmodule Zaq.System.OperationModelConfig do
  @moduledoc "Credential/model selections for dedicated operations, with generation-only sampling."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :credential_id, :integer
    field :model, :string
    field :temperature, :float, default: 0.0
    field :top_p, :float, default: 0.9
  end

  @doc "Validates a model selection; only generation selections accept sampling parameters."
  @spec changeset(t(), map(), :generation | :decision | :reranking) :: Ecto.Changeset.t()
  def changeset(config, attrs, purpose \\ :generation) do
    fields =
      if purpose == :generation,
        do: [:credential_id, :model, :temperature, :top_p],
        else: [:credential_id, :model]

    changeset = cast(config, attrs, fields)

    changeset =
      if get_field(changeset, :credential_id) || get_field(changeset, :model) do
        changeset
        |> validate_required([:credential_id, :model])
        |> validate_number(:credential_id, greater_than: 0)
      else
        changeset
      end

    validate_sampling(changeset, purpose)
  end

  defp validate_sampling(changeset, :generation) do
    changeset
    |> validate_required([:temperature, :top_p])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:top_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
  end

  defp validate_sampling(changeset, purpose) when purpose in [:decision, :reranking],
    do: changeset

  @doc "Text output is required; an unknown catalog entry is handled by custom-model selection."
  @spec supports?(map(), :generation | :decision | :reranking) :: boolean()
  def supports?(model, purpose \\ :generation)

  def supports?(model, :generation) do
    output = Map.get(Map.get(model, :modalities) || %{}, :output) || []
    :text in output
  end

  def supports?(model, :reranking),
    do: get_in(model, [Access.key(:capabilities, %{}), :rerank]) == true

  def supports?(model, :decision) do
    output = get_in(model, [Access.key(:modalities, %{}), :output]) || []
    :decisions in output
  end
end
