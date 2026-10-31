defmodule Zaq.Contracts.PreparationProgress do
  @moduledoc """
  Shared validation for preparation progress received from Python and stored as JSON.

  Fields are optional: counters must be integers and stage, status and label must
  be strings or null. Negative and overflowing counters remain renderable; the UI
  clamps progress bounds. Unknown string keys are allowed for future stages.
  """

  @doc "Returns whether a payload's supported fields are safe to render and persist."
  @spec valid?(term()) :: boolean()
  def valid?(payload) when is_map(payload) and not is_struct(payload) do
    Enum.all?(payload, fn
      {key, value} when key in ["current", "total"] ->
        is_integer(value)

      {key, value} when key in ["stage", "status", "label"] ->
        is_binary(value) or is_nil(value)

      {key, _value} ->
        is_binary(key)
    end)
  end

  def valid?(_payload), do: false
end
