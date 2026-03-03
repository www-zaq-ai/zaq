defmodule Zaq.Agent.TokenEstimator do
  @moduledoc """
  Simple token estimation utility.

  Uses a word-based heuristic (words × 1.3) to estimate token counts
  without requiring heavy dependencies like Bumblebee/Nx/Torchx.
  """

  @ratio 1.3

  @doc """
  Estimates the number of tokens in the given text.

  Uses the approximation: `word_count × 1.3`, rounded up.

  ## Examples

      iex> Zaq.Agent.TokenEstimator.estimate("Hello world")
      3

      iex> Zaq.Agent.TokenEstimator.estimate("")
      0
  """
  @spec estimate(String.t()) :: non_neg_integer()
  def estimate(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
    |> Kernel.*(@ratio)
    |> ceil()
  end

  def estimate(_), do: 0
end
