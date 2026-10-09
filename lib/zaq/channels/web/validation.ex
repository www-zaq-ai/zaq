defmodule Zaq.Channels.Web.Validation do
  @moduledoc false

  @max_identifier_bytes 255

  @spec reject_unknown_fields(map(), [atom()]) :: :ok | {:error, {:unknown_fields, [String.t()]}}
  def reject_unknown_fields(attrs, allowed) when is_map(attrs) do
    allowed = MapSet.new(Enum.flat_map(allowed, &[&1, Atom.to_string(&1)]))

    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    if unknown == [], do: :ok, else: {:error, {:unknown_fields, unknown}}
  end

  @spec fetch(map(), atom()) :: term()
  def fetch(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  @spec identifier(term(), atom(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def identifier(value, field, opts \\ []) do
    required? = Keyword.get(opts, :required, false)

    case normalized_string(value, @max_identifier_bytes) do
      nil when required? -> {:error, {:invalid_field, field}}
      nil -> {:ok, nil}
      normalized -> {:ok, normalized}
    end
  end

  @spec required_text(term(), atom(), pos_integer()) ::
          {:ok, String.t()} | {:error, {:invalid_field, atom()}}
  def required_text(value, field, max_bytes) do
    case normalized_string(value, max_bytes) do
      nil -> {:error, {:invalid_field, field}}
      normalized -> {:ok, normalized}
    end
  end

  @spec map(term(), atom()) :: {:ok, map()} | {:error, {:invalid_field, atom()}}
  def map(nil, _field), do: {:ok, %{}}
  def map(value, _field) when is_map(value), do: {:ok, value}
  def map(_value, field), do: {:error, {:invalid_field, field}}

  @spec list(term(), atom()) :: {:ok, list()} | {:error, {:invalid_field, atom()}}
  def list(nil, _field), do: {:ok, []}
  def list(value, _field) when is_list(value), do: {:ok, value}
  def list(_value, field), do: {:error, {:invalid_field, field}}

  @spec forbidden_keys(map(), [atom()], atom()) :: :ok | {:error, tuple()}
  def forbidden_keys(value, forbidden, error_tag) when is_map(value) do
    forbidden = MapSet.new(Enum.flat_map(forbidden, &[&1, Atom.to_string(&1)]))

    found =
      value
      |> collect_keys([])
      |> Enum.filter(&MapSet.member?(forbidden, &1))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()
      |> Enum.sort()

    if found == [], do: :ok, else: {:error, {error_tag, found}}
  end

  defp normalized_string(value, max_bytes) when is_binary(value) do
    normalized = String.trim(value)

    if normalized != "" and byte_size(normalized) <= max_bytes, do: normalized
  end

  defp normalized_string(_value, _max_bytes), do: nil

  defp collect_keys(map, acc) when is_map(map) do
    map
    |> :maps.to_list()
    |> Enum.reduce(acc, fn {key, value}, keys -> collect_keys(value, [key | keys]) end)
  end

  defp collect_keys(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_keys/2)

  defp collect_keys(_value, acc), do: acc
end
