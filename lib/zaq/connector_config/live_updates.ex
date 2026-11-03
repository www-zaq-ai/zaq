defmodule Zaq.ConnectorConfig.LiveUpdates do
  @moduledoc """
  Pure validation and defaults for connector-owned streamed-update policies.

  Only answer content, reasoning and tool activity can be configured as triggers.
  Status messages are unaffected, so disabling this policy does not imply final-only
  display. Trigger selection never filters snapshot contents or trace collection.
  Missing fields use defaults; explicit invalid values are rejected. All persisted
  keys and values are JSON-compatible, and unrelated connector settings stay opaque.
  """

  @triggers ~w(stream_delta reasoning tool_call)
  @keys ~w(enabled throttle_enabled min_interval_ms triggers)
  @defaults %{
    "enabled" => true,
    "throttle_enabled" => true,
    "min_interval_ms" => 100,
    "triggers" => Map.new(@triggers, &{&1, true})
  }

  @type policy :: %{String.t() => boolean() | pos_integer() | %{String.t() => boolean()}}
  @type errors :: %{String.t() => String.t()}

  @doc "Default policy for an absent subtree or configless BO execution."
  @spec defaults() :: policy()
  def defaults, do: @defaults

  @doc "Reads only the live_updates subtree, distinguishing absence from malformed data."
  @spec from_settings(term()) :: {:ok, policy()} | {:error, errors()}
  def from_settings(settings) when is_map(settings) do
    case Map.fetch(settings, "live_updates") do
      :error -> {:ok, defaults()}
      {:ok, policy} -> normalize(policy)
    end
  end

  def from_settings(_settings), do: {:error, %{"live_updates" => "must be a settings map"}}

  @doc "Validates stored JSON values and fills absent fields, never coercing booleans."
  @spec normalize(term()) :: {:ok, policy()} | {:error, errors()}
  def normalize(policy) when is_map(policy) do
    normalized = Map.merge(defaults(), policy)

    errors =
      policy
      |> unknown_keys(@keys, "live_updates")
      |> validate_booleans(normalized, ~w(enabled throttle_enabled), "")
      |> validate_interval(normalized["min_interval_ms"])
      |> validate_triggers(normalized["triggers"])

    if map_size(errors) == 0 do
      {:ok, Map.update!(normalized, "triggers", &Map.merge(@defaults["triggers"], &1))}
    else
      {:error, errors}
    end
  end

  def normalize(_policy), do: {:error, %{"live_updates" => "must be a map"}}

  @doc "Normalizes known HTML boolean/integer values before strict validation."
  @spec normalize_form(term()) :: {:ok, policy()} | {:error, errors()}
  def normalize_form(policy) when is_map(policy) do
    policy
    |> Map.new(fn
      {"triggers", triggers} when is_map(triggers) ->
        {"triggers", Map.new(triggers, fn {key, value} -> {key, form_boolean(value)} end)}

      {key, value} when key in ["enabled", "throttle_enabled"] ->
        {key, form_boolean(value)}

      {"min_interval_ms", value} when is_binary(value) ->
        {"min_interval_ms", form_integer(value)}

      entry ->
        entry
    end)
    |> normalize()
  end

  def normalize_form(policy), do: normalize(policy)

  defp unknown_keys(map, allowed, path) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: %{},
      else: %{path => "contains unknown fields"}
  end

  defp validate_booleans(errors, map, keys, prefix) do
    Enum.reduce(keys, errors, fn key, errors ->
      if is_boolean(map[key]),
        do: errors,
        else: Map.put(errors, prefix <> key, "must be true or false")
    end)
  end

  defp validate_interval(errors, value) when is_integer(value) and value > 0, do: errors

  defp validate_interval(errors, _value),
    do: Map.put(errors, "min_interval_ms", "must be a positive integer")

  defp validate_triggers(errors, triggers) when is_map(triggers) do
    errors
    |> Map.merge(unknown_keys(triggers, @triggers, "triggers"))
    |> validate_booleans(Map.merge(@defaults["triggers"], triggers), @triggers, "triggers.")
  end

  defp validate_triggers(errors, _triggers),
    do: Map.put(errors, "triggers", "must be a map")

  defp form_boolean("true"), do: true
  defp form_boolean("false"), do: false
  defp form_boolean(value), do: value

  defp form_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> value
    end
  end
end
