defmodule Zaq.Types.JsonArray do
  @moduledoc """
  Custom Ecto type for JSONB columns that store a JSON array (`[]`).

  Ecto's built-in `:map` type only accepts Elixir maps. This type accepts lists
  (and maps) so a `jsonb` column containing `[]` round-trips correctly.

  Used for `notification_logs.channels_tried` and similar audit-trail columns.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value) when is_list(value) or is_map(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def load(value), do: {:ok, value}

  @impl Ecto.Type
  def dump(value) when is_list(value) or is_map(value), do: {:ok, value}
  def dump(_), do: :error
end
