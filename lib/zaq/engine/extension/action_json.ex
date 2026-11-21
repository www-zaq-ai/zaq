defmodule Zaq.Engine.Extension.ActionJson do
  @moduledoc """
  Bounded JSON conversion for Extension arguments and results.
  Container depth is checked before decoding; unsupported BEAM terms cannot be
  rendered as successful results by an incidental Jason protocol implementation.
  """

  @doc "Decodes a UTF-8 JSON object without exceeding the negotiated container depth."
  @spec decode_object(binary(), pos_integer()) :: {:ok, map()} | :error
  def decode_object(json, max_depth) do
    with true <- String.valid?(json),
         :ok <- scan(json, max_depth, 0, false, false),
         {:ok, %Jason.OrderedObject{} = object} <- Jason.decode(json, objects: :ordered_objects),
         true <- unique_keys?(object) do
      {:ok, plain_object(object)}
    else
      _ -> :error
    end
  end

  @doc "Encodes JSON-compatible values only, rejecting opaque terms and excessive depth."
  @spec encode(term(), pos_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, :too_large} | :error
  def encode(value, max_depth, max_bytes \\ 8_388_608) do
    if compatible?(value, max_depth) do
      case Jason.encode_to_iodata(value, maps: :strict) do
        {:ok, iodata} ->
          bounded_binary(iodata, max_bytes)

        _ ->
          :error
      end
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp bounded_binary(iodata, max_bytes) do
    if IO.iodata_length(iodata) <= max_bytes,
      do: {:ok, IO.iodata_to_binary(iodata)},
      else: {:error, :too_large}
  end

  defp unique_keys?(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))
    length(keys) == MapSet.size(MapSet.new(keys)) and Enum.all?(pairs, &unique_keys?(elem(&1, 1)))
  end

  defp unique_keys?(values) when is_list(values), do: Enum.all?(values, &unique_keys?/1)
  defp unique_keys?(_scalar), do: true

  defp plain_object(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, plain_object(value)} end)

  defp plain_object(values) when is_list(values), do: Enum.map(values, &plain_object/1)
  defp plain_object(scalar), do: scalar

  defp scan(<<>>, _max, _depth, _quoted, _escaped), do: :ok
  defp scan(<<_, rest::binary>>, max, depth, true, true), do: scan(rest, max, depth, true, false)
  defp scan(<<92, rest::binary>>, max, depth, true, false), do: scan(rest, max, depth, true, true)

  defp scan(<<34, rest::binary>>, max, depth, quoted, false),
    do: scan(rest, max, depth, not quoted, false)

  defp scan(<<char, rest::binary>>, max, depth, false, false) when char in [123, 91] do
    if depth < max, do: scan(rest, max, depth + 1, false, false), else: :error
  end

  defp scan(<<char, rest::binary>>, max, depth, false, false) when char in [125, 93],
    do: scan(rest, max, depth - 1, false, false)

  defp scan(<<_, rest::binary>>, max, depth, quoted, escaped),
    do: scan(rest, max, depth, quoted, escaped)

  defp compatible?(value, _depth) when is_number(value) or is_atom(value),
    do: true

  defp compatible?(value, _depth) when is_binary(value), do: String.valid?(value)
  defp compatible?(%_struct{}, _depth), do: false

  defp compatible?(value, depth) when is_map(value) and depth > 0 do
    Enum.all?(value, fn {key, nested} ->
      (is_atom(key) or (is_binary(key) and String.valid?(key))) and compatible?(nested, depth - 1)
    end)
  end

  defp compatible?(value, depth) when is_list(value) and depth > 0,
    do: Enum.all?(value, &compatible?(&1, depth - 1))

  defp compatible?(_value, _depth), do: false
end
