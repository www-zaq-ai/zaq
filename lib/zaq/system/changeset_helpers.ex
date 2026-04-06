defmodule Zaq.System.ChangesetHelpers do
  @moduledoc false

  import Ecto.Changeset, only: [get_field: 2, add_error: 3]

  @doc "Validates that `chunk_max_tokens` is greater than `chunk_min_tokens`."
  def validate_chunk_order(changeset) do
    min = get_field(changeset, :chunk_min_tokens)
    max = get_field(changeset, :chunk_max_tokens)

    if min && max && min >= max do
      add_error(changeset, :chunk_max_tokens, "must be greater than min tokens")
    else
      changeset
    end
  end
end
