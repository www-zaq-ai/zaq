defmodule Zaq.System.ImageToTextConfig do
  @moduledoc "Embedded schema for validating Image-to-Text configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :provider, :string, default: "custom"
    field :api_url, :string, default: "http://localhost:11434/v1"
    field :api_key, :string, default: ""
    field :model, :string, default: "pixtral-12b-2409"
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:provider, :api_url, :api_key, :model])
    |> validate_required([:api_url, :model])
  end
end
