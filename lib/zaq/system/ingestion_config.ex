defmodule Zaq.System.IngestionConfig do
  @moduledoc "Embedded schema for validating ingestion configuration."

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :max_context_window, :integer, default: 5_000
    field :distance_threshold, :float, default: 1.2
    field :hybrid_search_limit, :integer, default: 20
    field :chunk_min_tokens, :integer, default: 400
    field :chunk_max_tokens, :integer, default: 900
    field :base_path, :string, default: "/zaq/volumes/documents"
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :max_context_window,
      :distance_threshold,
      :hybrid_search_limit,
      :chunk_min_tokens,
      :chunk_max_tokens,
      :base_path
    ])
    |> validate_required([:base_path])
    |> validate_number(:max_context_window, greater_than: 0)
    |> validate_number(:distance_threshold, greater_than: 0.0)
    |> validate_number(:hybrid_search_limit, greater_than: 0)
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
