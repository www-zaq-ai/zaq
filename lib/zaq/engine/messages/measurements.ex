defmodule Zaq.Engine.Messages.Measurements do
  @moduledoc """
  Normalizes message measurement maps at the engine/message boundary.

  Runtime metadata can contain provider-facing token names, while persisted
  messages have dedicated token columns. This module keeps that boundary explicit.
  """

  @not_provided "not provided"
  @token_measurement_keys [
    :input_tokens,
    :output_tokens,
    :prompt_tokens,
    :completion_tokens,
    :total_tokens,
    "input_tokens",
    "output_tokens",
    "prompt_tokens",
    "completion_tokens",
    "total_tokens"
  ]

  @doc "Returns measurements safe to persist in metadata fields."
  def metadata_measurements(measurements) when is_map(measurements),
    do: Map.drop(measurements, @token_measurement_keys)

  def metadata_measurements(_), do: %{}

  @doc "Returns the complete measurement map used by message-info popins."
  def message_info_measurements(message) when is_map(message) do
    message
    |> source_measurements()
    |> metadata_measurements()
    |> Map.merge(token_measurements_from_message(message))
  end

  def message_info_measurements(_message), do: %{}

  @doc "Returns popin token measurements from dedicated message columns."
  def token_measurements_from_message(message) when is_map(message) do
    %{
      "prompt_tokens" => message |> value(:prompt_tokens) |> provided_value(),
      "completion_tokens" => message |> value(:completion_tokens) |> provided_value(),
      "total_tokens" => message |> value(:total_tokens) |> provided_value()
    }
  end

  def token_measurements_from_message(_message) do
    %{
      "prompt_tokens" => @not_provided,
      "completion_tokens" => @not_provided,
      "total_tokens" => @not_provided
    }
  end

  @doc "Reads a value from atom or string keys."
  def value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  def value(_map, _key), do: nil

  defp source_measurements(message) do
    metadata = value(message, :metadata)

    case value(metadata, :measurements) do
      measurements when is_map(measurements) -> measurements
      _ -> value(message, :measurements)
    end
  end

  defp provided_value(nil), do: @not_provided
  defp provided_value(value), do: value
end
