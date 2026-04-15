defmodule Zaq.System.EmbeddingConfig do
  @moduledoc "Embedded schema for validating Embedding configuration."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.System.ChangesetHelpers

  embedded_schema do
    field :credential_id, :integer
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
      :credential_id,
      :provider,
      :endpoint,
      :api_key,
      :model,
      :dimension,
      :chunk_min_tokens,
      :chunk_max_tokens
    ])
    |> validate_required([:credential_id, :model, :dimension])
    |> validate_number(:dimension, greater_than: 0, less_than_or_equal_to: 4000)
    |> validate_number(:chunk_min_tokens, greater_than: 0)
    |> validate_number(:chunk_max_tokens, greater_than: 0)
    |> ChangesetHelpers.validate_chunk_order()
  end
end
