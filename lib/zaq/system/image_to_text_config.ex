defmodule Zaq.System.ImageToTextConfig do
  @moduledoc "Embedded schema for validating Image-to-Text configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :credential_id, :integer
    field :provider, :string, default: "custom"
    field :endpoint, :string, default: "http://localhost:11434/v1"
    field :api_key, :string, default: ""
    field :model, :string, default: "pixtral-12b-2409"
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:credential_id, :model])
    |> validate_required([:credential_id, :model])
  end
end
