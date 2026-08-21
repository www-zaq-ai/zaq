defmodule Zaq.Agent.MaterializationAliases do
  @moduledoc """
  Agent-only aliases for materialization handles in model-facing tool calls.

  Canonical signed handles remain the contract for actions, workflows, and stored
  results. This module only rewrites schema-declared handle paths as data moves
  through Jido AI tool interception.
  """

  alias Jido.RuntimeStore
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Materialization.Handle

  @hive :materialization_aliases
  @jido_instance Zaq.Agent.Jido
  @alias_prefix "mat_"
  @alias_bytes 18

  @type tool_call :: %{required(:arguments) => map(), required(:action_module) => module()}
  @type result :: {:ok, term(), [term()]} | {:error, term(), [term()]}

  @doc "Expands short materialization aliases in a tool call to full signed handles."
  @spec expand_tool_call(tool_call(), map()) :: {:ok, tool_call()} | {:error, term()}
  def expand_tool_call(%{arguments: arguments, action_module: action_module} = tool_call, context)
      when is_map(arguments) and is_atom(action_module) do
    original_module = action_module

    with {:ok, schema} <- action_schema(action_module, :schema),
         paths <- handle_paths(schema) do
      maybe_map_scoped(arguments, paths, context, &expand_value/2, fn arguments ->
        %{tool_call | arguments: arguments, action_module: original_module}
      end)
    end
  end

  def expand_tool_call(tool_call, _context), do: {:ok, tool_call}

  @doc "Projects full signed materialization handles in a tool result to short aliases."
  @spec alias_tool_result(tool_call(), result(), map()) :: {:ok, result()} | {:error, term()}
  def alias_tool_result(%{action_module: action_module}, {:ok, output, effects}, context)
      when is_atom(action_module) do
    with {:ok, schema} <- action_schema(action_module, :output_schema),
         paths <- handle_paths(schema) do
      maybe_map_scoped(output, paths, context, &alias_value/2, fn output ->
        {:ok, output, effects}
      end)
    end
  end

  def alias_tool_result(_tool_call, result, _context), do: {:ok, result}

  @doc false
  @spec clear_scope(term()) :: :ok
  def clear_scope(scope) do
    @jido_instance
    |> RuntimeStore.list(@hive)
    |> Enum.each(fn
      {{^scope, _kind, _value} = key, _stored} -> RuntimeStore.delete(@jido_instance, @hive, key)
      {_key, _stored} -> :ok
    end)

    :ok
  end

  @doc "Returns JSON-safe Record metadata with materialization handles scoped to short aliases."
  @spec alias_record_metadata(Record.t(), term()) :: {:ok, map()} | {:error, term()}
  def alias_record_metadata(%Record{} = record, scope) do
    record
    |> Record.metadata()
    |> alias_metadata(scope)
  end

  @doc "Aliases a serialized Record metadata map for model-facing history text."
  @spec alias_metadata(map(), term()) :: {:ok, map()} | {:error, term()}
  def alias_metadata(metadata, scope) when is_map(metadata) do
    map_paths(
      metadata,
      [[:materialization_handle], ["materialization_handle"]],
      &alias_value(&1, scope)
    )
  end

  defp fetch_scope(%{materialization_alias_scope: scope}) when not is_nil(scope), do: {:ok, scope}

  defp fetch_scope(%{"materialization_alias_scope" => scope}) when not is_nil(scope),
    do: {:ok, scope}

  defp fetch_scope(_context), do: {:error, :missing_materialization_alias_scope}

  defp action_schema(module, function) do
    if function_exported?(module, function, 0),
      do: {:ok, apply(module, function, [])},
      else: {:ok, []}
  end

  defp handle_paths(schema), do: collect_paths(schema, []) |> Enum.uniq()

  defp maybe_map_scoped(value, [], _context, _mapper, wrap), do: {:ok, wrap.(value)}

  defp maybe_map_scoped(value, paths, context, mapper, wrap) do
    with {:ok, scope} <- fetch_scope(context),
         {:ok, value} <- map_paths(value, paths, &mapper.(&1, scope)) do
      {:ok, wrap.(value)}
    end
  end

  defp collect_paths(%Zoi.Types.Map{fields: fields}, path) when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Struct{module: Record}, path),
    do: [path ++ [:materialization_handle]]

  defp collect_paths(%Zoi.Types.Struct{module: RecordPage, fields: nil}, path),
    do: [path ++ [:records, :*, :materialization_handle]]

  defp collect_paths(%Zoi.Types.Struct{module: RecordPage, fields: fields}, path)
       when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Struct{fields: fields}, path) when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Array{inner: inner}, path), do: collect_paths(inner, path ++ [:*])
  defp collect_paths(%Zoi.Types.Default{inner: inner}, path), do: collect_paths(inner, path)

  defp collect_paths(%Zoi.Types.Union{schemas: schemas}, path) do
    Enum.flat_map(schemas, &collect_paths(&1, path))
  end

  defp collect_paths(%{meta: %{metadata: metadata}}, path) do
    semantic_type = Keyword.get(metadata || [], :zaq_semantic_type)

    cond do
      semantic_type == Handle.semantic_type() -> [path]
      semantic_type == Record.semantic_type() -> [path ++ [:materialization_handle]]
      true -> []
    end
  end

  defp collect_paths(schema, path) when is_list(schema) do
    Enum.flat_map(schema, fn
      {key, opts} when is_list(opts) -> collect_nimble_path(key, opts, path)
      _other -> []
    end)
  end

  defp collect_paths(_schema, _path), do: []

  defp collect_nimble_path(key, opts, path) do
    case Keyword.get(opts, :type) do
      {:struct, Record} -> [path ++ [key, :materialization_handle]]
      {:struct, RecordPage} -> [path ++ [key, :records, :*, :materialization_handle]]
      {:list, {:struct, Record}} -> [path ++ [key, :*, :materialization_handle]]
      _other -> []
    end
  end

  defp map_paths(value, paths, fun) do
    Enum.reduce_while(paths, {:ok, value}, fn path, {:ok, acc} ->
      case update_path(acc, path, fun) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_path(values, [:* | rest], fun) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case update_path(value, rest, fun) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      error -> error
    end)
  end

  defp update_path(value, [:* | _rest], _fun), do: {:ok, value}
  defp update_path(value, [], fun), do: fun.(value)

  defp update_path(value, [key | rest], fun) when is_map(value) do
    case fetch_existing_key(value, key) do
      {:ok, actual_key, child} ->
        with {:ok, updated_child} <- update_path(child, rest, fun) do
          {:ok, Map.put(value, actual_key, updated_child)}
        end

      :error ->
        {:ok, value}
    end
  end

  defp update_path(value, _path, _fun), do: {:ok, value}

  defp fetch_existing_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, key, Map.fetch!(map, key)}

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        string_key = Atom.to_string(key)
        {:ok, string_key, Map.fetch!(map, string_key)}

      is_binary(key) ->
        atom_key = String.to_existing_atom(key)

        if Map.has_key?(map, atom_key) do
          {:ok, atom_key, Map.fetch!(map, atom_key)}
        else
          :error
        end

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp expand_value(value, _scope) when not is_binary(value), do: {:ok, value}
  defp expand_value(@alias_prefix <> _ = alias, scope), do: fetch_alias(scope, alias)
  defp expand_value(value, _scope), do: {:ok, value}

  defp alias_value(value, _scope) when not is_binary(value), do: {:ok, value}
  defp alias_value(@alias_prefix <> _ = value, _scope), do: {:ok, value}

  defp alias_value(value, scope) do
    key = {scope, :handle, value}

    case RuntimeStore.fetch(@jido_instance, @hive, key) do
      {:ok, alias} ->
        {:ok, alias}

      :error ->
        alias = short_alias(value)

        with :ok <- RuntimeStore.put(@jido_instance, @hive, {scope, :alias, alias}, value),
             :ok <- RuntimeStore.put(@jido_instance, @hive, key, alias) do
          {:ok, alias}
        end
    end
  end

  defp fetch_alias(scope, alias) do
    case RuntimeStore.fetch(@jido_instance, @hive, {scope, :alias, alias}) do
      {:ok, handle} -> {:ok, handle}
      :error -> {:error, {:unknown_materialization_alias, alias}}
    end
  end

  defp short_alias(handle) do
    digest = :crypto.hash(:sha256, handle) |> Base.url_encode64(padding: false)
    @alias_prefix <> binary_part(digest, 0, @alias_bytes)
  end
end
