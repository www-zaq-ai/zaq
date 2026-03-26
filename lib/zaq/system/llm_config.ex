defmodule Zaq.System.LLMConfig do
  @moduledoc "Embedded schema for validating LLM configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :provider, :string, default: "custom"
    field :endpoint, :string, default: "http://localhost:11434/v1"
    field :api_key, :string, default: ""
    field :model, :string, default: "llama-3.3-70b-instruct"
    field :temperature, :float, default: 0.0
    field :top_p, :float, default: 0.9
    field :supports_logprobs, :boolean, default: true
    field :supports_json_mode, :boolean, default: true
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :provider,
      :endpoint,
      :api_key,
      :model,
      :temperature,
      :top_p,
      :supports_logprobs,
      :supports_json_mode
    ])
    |> validate_required([:endpoint, :model])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:top_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
  end
end
