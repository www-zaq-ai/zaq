defmodule Zaq.System.LLMConfig do
  @moduledoc "Embedded schema for validating LLM configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :credential_id, :integer
    field :provider, :string, default: "custom"
    field :endpoint, :string, default: "http://localhost:11434/v1"
    field :api_key, :string, default: ""
    field :model, :string, default: "llama-3.3-70b-instruct"
    field :temperature, :float, default: 0.0
    field :top_p, :float, default: 0.9
    field :path, :string, default: "/chat/completions"
    field :supports_logprobs, :boolean, default: true
    field :supports_json_mode, :boolean, default: true
    field :max_context_window, :integer, default: 5_000
    field :distance_threshold, :float, default: 1.2
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :credential_id,
      :provider,
      :endpoint,
      :api_key,
      :model,
      :temperature,
      :top_p,
      :path,
      :supports_logprobs,
      :supports_json_mode,
      :max_context_window,
      :distance_threshold
    ])
    |> validate_required([:credential_id, :model])
    |> validate_number(:temperature, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 2.0)
    |> validate_number(:top_p, greater_than: 0.0, less_than_or_equal_to: 1.0)
    |> validate_number(:max_context_window, greater_than: 0)
    |> validate_number(:distance_threshold, greater_than: 0.0)
  end
end
