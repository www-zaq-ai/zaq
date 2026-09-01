defmodule Zaq.Agent.OpaqueAliases do
  @moduledoc """
  Agent-only aliases for signed Record values in model-facing tool calls.

  Canonical signed handles and provenance tokens remain the contract for actions,
  workflows, and stored results. This module only rewrites schema-declared paths
  as data moves through Jido AI tool interception.
  """

  alias Jido.RuntimeStore
  alias Zaq.Contracts.{Record, RecordPage}
  alias Zaq.Materialization.Handle

  @hive :opaque_aliases
  @jido_instance Zaq.Agent.Jido
  @alias_prefix "mat_"
  @provenance_alias_prefix "prov_"
  @alias_bytes 18

  @type tool_call :: %{required(:arguments) => map(), required(:action_module) => module()}
  @type result :: {:ok, term(), [term()]} | {:error, term(), [term()]}

  @doc "Expands short opaque aliases in a tool call to full signed values."
  @spec expand_tool_call(tool_call(), map()) :: {:ok, tool_call()} | {:error, term()}
  def expand_tool_call(%{arguments: arguments, action_module: action_module} = tool_call, context)
      when is_map(arguments) and is_atom(action_module) do
    original_module = action_module

    with {:ok, schema} <- action_schema(action_module, :schema),
         paths <- alias_paths(schema) do
      maybe_map_scoped(arguments, paths, context, &expand_value/3, fn arguments ->
        %{tool_call | arguments: arguments, action_module: original_module}
      end)
    end
  end

  def expand_tool_call(tool_call, _context), do: {:ok, tool_call}

  @doc "Projects full signed opaque values in a tool result to short aliases."
  @spec alias_tool_result(tool_call(), result(), map()) :: {:ok, result()} | {:error, term()}
  def alias_tool_result(%{action_module: action_module}, {:ok, output, effects}, context)
      when is_atom(action_module) do
    with {:ok, schema} <- action_schema(action_module, :output_schema),
         paths <- alias_paths(schema) do
      maybe_map_scoped(output, paths, context, &alias_value/3, fn output ->
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

  @doc "Returns JSON-safe Record metadata with signed values scoped to short aliases."
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
      [
        {[:materialization_handle], :handle},
        {["materialization_handle"], :handle},
        {[:provenance_ref], :provenance},
        {["provenance_ref"], :provenance}
      ],
      &alias_value(&1, &2, scope)
    )
  end

  defp fetch_scope(%{opaque_alias_scope: scope}) when not is_nil(scope), do: {:ok, scope}

  defp fetch_scope(%{"opaque_alias_scope" => scope}) when not is_nil(scope),
    do: {:ok, scope}

  defp fetch_scope(_context), do: {:error, :missing_opaque_alias_scope}

  defp action_schema(module, function) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, 0) do
      {:ok, apply(module, function, [])}
    else
      _other -> {:ok, []}
    end
  end

  defp alias_paths(schema), do: collect_paths(schema, []) |> Enum.uniq()

  defp maybe_map_scoped(value, [], _context, _mapper, wrap), do: {:ok, wrap.(value)}

  defp maybe_map_scoped(value, paths, context, mapper, wrap) do
    with {:ok, scope} <- fetch_scope(context),
         {:ok, value} <- map_paths(value, paths, &mapper.(&1, &2, scope)) do
      {:ok, wrap.(value)}
    end
  end

  defp collect_paths(%Zoi.Types.Map{fields: fields}, path) when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Struct{module: Record}, path),
    do: record_alias_paths(path)

  defp collect_paths(%Zoi.Types.Struct{module: RecordPage, fields: nil}, path),
    do: record_alias_paths(path ++ [:records, :*])

  defp collect_paths(%Zoi.Types.Struct{module: RecordPage, fields: fields}, path)
       when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Struct{fields: fields}, path) when is_list(fields) do
    Enum.flat_map(fields, fn {key, schema} -> collect_paths(schema, path ++ [key]) end)
  end

  defp collect_paths(%Zoi.Types.Array{inner: %{meta: %{metadata: metadata}} = inner}, path) do
    semantic_paths(metadata, path ++ [:*]) ++ collect_paths(inner, path ++ [:*])
  end

  defp collect_paths(%Zoi.Types.Array{inner: inner}, path), do: collect_paths(inner, path ++ [:*])
  defp collect_paths(%Zoi.Types.Default{inner: inner}, path), do: collect_paths(inner, path)

  defp collect_paths(%Zoi.Types.Union{schemas: schemas}, path) do
    Enum.flat_map(schemas, &collect_paths(&1, path))
  end

  defp collect_paths(%Zoi.Types.Any{meta: %{metadata: metadata}}, path) do
    semantic_paths(metadata, path)
  end

  defp collect_paths(%{meta: %{metadata: metadata}}, path) do
    semantic_paths(metadata, path)
  end

  defp collect_paths(schema, path) when is_list(schema) do
    Enum.flat_map(schema, fn
      {key, opts} when is_list(opts) -> collect_nimble_path(key, opts, path)
      _other -> []
    end)
  end

  defp collect_paths(_schema, _path), do: []

  defp semantic_paths(metadata, path) do
    semantic_type = Keyword.get(metadata || [], :zaq_semantic_type)

    cond do
      semantic_type == Handle.semantic_type() -> [{path, :handle}]
      semantic_type == Record.semantic_type() -> record_alias_paths(path)
      true -> []
    end
  end

  defp collect_nimble_path(key, opts, path) do
    case Keyword.get(opts, :type) do
      {:struct, Record} -> record_alias_paths(path ++ [key])
      {:struct, RecordPage} -> record_alias_paths(path ++ [key, :records, :*])
      {:list, {:struct, Record}} -> record_alias_paths(path ++ [key, :*])
      _other -> []
    end
  end

  defp record_alias_paths(path) do
    [
      {path ++ [:materialization_handle], :handle},
      {path ++ [:provenance_ref], :provenance}
    ]
  end

  defp map_paths(value, paths, fun) do
    Enum.reduce_while(paths, {:ok, value}, fn {path, kind}, {:ok, acc} ->
      case update_path(acc, path, kind, fun) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_path(values, [:* | rest], kind, fun) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case update_path(value, rest, kind, fun) do
        {:ok, updated} -> {:cont, {:ok, [updated | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, updated} -> {:ok, Enum.reverse(updated)}
      error -> error
    end)
  end

  defp update_path(value, [:* | _rest], _kind, _fun), do: {:ok, value}
  defp update_path(value, [], kind, fun), do: fun.(value, kind)

  defp update_path(value, [key | rest], kind, fun) when is_map(value) do
    case fetch_existing_key(value, key) do
      {:ok, actual_key, child} ->
        with {:ok, updated_child} <- update_path(child, rest, kind, fun) do
          {:ok, Map.put(value, actual_key, updated_child)}
        end

      :error ->
        {:ok, value}
    end
  end

  defp update_path(value, _path, _kind, _fun), do: {:ok, value}

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

  defp expand_value(value, _kind, _scope) when not is_binary(value), do: {:ok, value}
  defp expand_value(@alias_prefix <> _ = alias, :handle, scope), do: fetch_alias(scope, alias)

  defp expand_value(@provenance_alias_prefix <> _ = alias, :provenance, scope),
    do: fetch_alias(scope, alias)

  defp expand_value(value, _kind, _scope), do: {:ok, value}

  defp alias_value(value, _kind, _scope) when not is_binary(value), do: {:ok, value}
  defp alias_value(@alias_prefix <> _ = value, :handle, _scope), do: {:ok, value}

  defp alias_value(@provenance_alias_prefix <> _ = value, :provenance, _scope),
    do: {:ok, value}

  defp alias_value(value, kind, scope) do
    key = {scope, kind, value}

    case RuntimeStore.fetch(@jido_instance, @hive, key) do
      {:ok, alias} ->
        {:ok, alias}

      :error ->
        alias = short_alias(kind, value)

        with :ok <- RuntimeStore.put(@jido_instance, @hive, {scope, :alias, alias}, value),
             :ok <- RuntimeStore.put(@jido_instance, @hive, key, alias) do
          {:ok, alias}
        end
    end
  end

  defp fetch_alias(scope, alias) do
    case RuntimeStore.fetch(@jido_instance, @hive, {scope, :alias, alias}) do
      {:ok, handle} -> {:ok, handle}
      :error -> {:error, {:unknown_opaque_alias, alias}}
    end
  end

  defp short_alias(:handle, value), do: short_alias(@alias_prefix, value)
  defp short_alias(:provenance, value), do: short_alias(@provenance_alias_prefix, value)

  defp short_alias(prefix, value) do
    digest = :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
    prefix <> binary_part(digest, 0, @alias_bytes)
  end
end
