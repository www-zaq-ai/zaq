defmodule Zaq.System.EmbeddingConfig do
  @moduledoc "Embedded schema for validating Embedding configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :provider, :string, default: "custom"
    field :endpoint, :string, default: "http://localhost:11434/v1"
    field :api_key, :string, default: ""
    field :model, :string, default: "bge-multilingual-gemma2"
    field :dimension, :integer, default: 3584
    field :chunk_min_tokens, :integer, default: 400
    field :chunk_max_tokens, :integer, default: 900
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :provider,
      :endpoint,
      :api_key,
      :model,
      :dimension,
      :chunk_min_tokens,
      :chunk_max_tokens
    ])
    |> validate_required([:endpoint, :model, :dimension])
    |> validate_number(:dimension, greater_than: 0, less_than_or_equal_to: 4000)
    |> validate_number(:chunk_min_tokens, greater_than: 0)
    |> validate_number(:chunk_max_tokens, greater_than: 0)
    |> validate_chunk_order()
  end

  defp validate_chunk_order(changeset) do
    min = get_field(changeset, :chunk_min_tokens)
    max = get_field(changeset, :chunk_max_tokens)

    if min && max && min >= max do
      add_error(changeset, :chunk_max_tokens, "must be greater than min tokens")
    else
      changeset
    end
  end
end
