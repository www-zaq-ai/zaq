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
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:provider, :endpoint, :api_key, :model, :dimension])
    |> validate_required([:endpoint, :model, :dimension])
    |> validate_number(:dimension, greater_than: 0)
  end
end
