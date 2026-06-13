defmodule Zaq.Helpers do
  @moduledoc """
  Small, dependency-free helper functions shared across contexts.

  Keep this module limited to pure, broadly-applicable predicates and
  transformations. Anything tied to a specific domain belongs in that domain's
  context, not here.
  """

  @doc """
  Returns `true` when `value` is `nil`, an empty string, or a string containing
  only whitespace.

  Non-`nil`, non-binary values are never considered blank.

      iex> Zaq.Helpers.blank?(nil)
      true
      iex> Zaq.Helpers.blank?("")
      true
      iex> Zaq.Helpers.blank?("   ")
      true
      iex> Zaq.Helpers.blank?("x")
      false
      iex> Zaq.Helpers.blank?(0)
      false
  """
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?(_), do: false
end
