defmodule Zaq.Agent.Tools.Registry do
  @moduledoc """
  Whitelisted tool registry for BO-managed custom agents.

  This module is intentionally code-configured so runtime declarations cannot
  execute arbitrary modules.
  """

  @type descriptor :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:description) => String.t(),
          required(:module) => module()
        }

  # Keep this list explicit and small until tools are implemented.
  @tools []

  @spec tools() :: [descriptor()]
  def tools, do: @tools

  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@tools, & &1.key)

  @spec valid_tool_key?(String.t()) :: boolean()
  def valid_tool_key?(tool_key) when is_binary(tool_key),
    do: Enum.any?(@tools, &(&1.key == tool_key))

  def valid_tool_key?(_), do: false

  @spec resolve_modules([String.t()]) ::
          {:ok, [module()]} | {:error, {:unknown_tools, [String.t()]}}
  def resolve_modules(tool_keys) when is_list(tool_keys) do
    by_key = Map.new(@tools, &{&1.key, &1.module})

    {modules, unknown} =
      Enum.reduce(tool_keys, {[], []}, fn key, {mods, missing} ->
        case Map.fetch(by_key, key) do
          {:ok, module} -> {[module | mods], missing}
          :error -> {mods, [key | missing]}
        end
      end)

    case unknown do
      [] -> {:ok, modules |> Enum.reverse() |> Enum.uniq()}
      missing -> {:error, {:unknown_tools, Enum.reverse(missing)}}
    end
  end

  def resolve_modules(_), do: {:error, {:unknown_tools, []}}

  @doc """
  Returns model tool-calling support from LLMDB.

  - `true`  => supports tools
  - `false` => explicitly does not support tools
  - `nil`   => unknown (provider/model not found)
  """
  @spec model_supports_tools?(String.t() | nil, String.t() | nil) :: boolean() | nil
  def model_supports_tools?(provider_id, model_id)

  def model_supports_tools?(provider_id, model_id)
      when provider_id in [nil, "", "custom"] or model_id in [nil, ""] do
    nil
  end

  def model_supports_tools?(provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    provider_atom = String.to_existing_atom(provider_id)

    case LLMDB.model(provider_atom, model_id) do
      {:ok, %{capabilities: capabilities}} ->
        case Map.get(capabilities || %{}, :tools) do
          true -> true
          false -> false
          tools when is_map(tools) -> map_size(tools) > 0
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
