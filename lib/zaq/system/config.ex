defmodule Zaq.System.Config do
  @moduledoc """
  Ecto schema for persistent system configuration key-value entries.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "system_configs" do
    field :key, :string
    field :value, :string

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
