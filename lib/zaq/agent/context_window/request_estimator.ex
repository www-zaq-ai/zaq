defmodule Zaq.Agent.ContextWindow.RequestEstimator do
  @moduledoc """
  Conservative request-size estimator for outbound LLM context-window checks.

  The estimate is intentionally based on a deterministic textual projection of
  the whole request shape, not only message contents, so tools, schemas, and
  relevant options are counted before a provider call is attempted.
  """

  @default_tokens_per_character 0.5

  @doc "Estimates request input tokens using a fixed character coefficient."
  @spec estimate(map(), map() | keyword()) :: non_neg_integer()
  def estimate(request, calibration \\ %{}) when is_map(request) do
    request
    |> character_count()
    |> Kernel.*(tokens_per_character(calibration))
    |> ceil()
  end

  @doc "Returns the deterministic character count used by `estimate/2`."
  @spec character_count(map()) :: non_neg_integer()
  def character_count(request) when is_map(request) do
    request
    |> Map.take([:messages, :llm_opts, :tools, :model, :output])
    |> normalize()
    |> Jason.encode!()
    |> String.length()
  end

  defp tokens_per_character(calibration) do
    value = value_from(calibration, :tokens_per_character) || @default_tokens_per_character

    if is_number(value) and value > 0 do
      value
    else
      @default_tokens_per_character
    end
  end

  defp value_from(%{} = map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp value_from(list, key) when is_list(list), do: Keyword.get(list, key)
  defp value_from(_other, _key), do: nil

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Map.new()
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: inspect(value)
end
