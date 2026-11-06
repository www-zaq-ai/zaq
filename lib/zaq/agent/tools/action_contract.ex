defmodule Zaq.Agent.Tools.ActionContract do
  @moduledoc """
  Canonical boundary for turning external (JSON, string-keyed) params into an
  invocation of a Jido Action.

  It owns three separate responsibilities:

    * `normalize/2` - schema-type aware key/value normalization. Dispatch over
      NimbleOptions, Zoi and JSON Schema is delegated to
      `Jido.Action.Tool.convert_params_using_schema/2` (known string keys become
      existing atoms, unknown keys are preserved, no atoms are created). On top
      of that it rehydrates atom enums, which Jido does not do: a validated
      param such as `level: :info` becomes `"info"` after a JSON round trip, so
      top-level string values of Nimble `{:in, atoms}` and Zoi atom `enum`
      fields are mapped back to the matching existing atom.
    * `validate/2` - normalization plus the action's own `validate_params/1`.
      It never calls `run/2`, so it is safe for scheduling and previews.
    * `execute/4` - normalization plus `Jido.Exec.run/4`. Jido owns validation,
      defaults, timeouts, retries and output validation; this module does not
      re-validate or re-implement them. Nested invocations inherit an optional
      `:on_tool_event` callback and receive their own `:tool_call_id` and
      `:tool_invocation_path`. Without a callback the default sends lifecycle
      events to `:tool_event_sink` using Jido's native request/run correlation.
      Missing tracing context keeps execution untraced. Trace failures never
      replace the Action result; workflow callbacks record synchronously.

  The caller identifies the action by module. This module is deliberately not a
  registry: `Zaq.Agent.Tools.Registry` stays the allowlist of actions exposed as
  model tools / schedulable, while workflow-composable actions can use the same
  contract without becoming tools.

  Errors are returned, never raised, for unloadable modules and modules that do
  not implement `validate_params/1`: `{:error, {:invalid_action, module, reason}}`.
  Validation failures are returned exactly as the action / Jido produce them.

  Not every call site goes through this module on purpose (for example
  `Zaq.Engine.Workflows.StepRunner` and back-office UI code call `run/2`
  directly). New actions do not need a particular schema format: keep the
  format used by the surrounding area; all three are supported here.
  """

  alias Jido.Action.Schema, as: ActionSchema
  alias Jido.Action.Tool
  alias Jido.AI.Observe
  alias Jido.AI.Request.Stream, as: RequestStream
  alias Jido.AI.Runtime.Event
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Agent.Tools.Error, as: ToolError
  alias Zaq.Contracts.Record

  require Logger

  @type error :: {:invalid_action, module(), term()}

  @doc "Normalizes external params against the action's declared input schema."
  @spec normalize(module(), map()) :: {:ok, map()} | {:error, error()}
  def normalize(module, params) when is_atom(module) and is_map(params) do
    with :ok <- ensure_loaded(module) do
      schema = module.schema()

      {:ok,
       params
       |> Tool.convert_params_using_schema(schema)
       |> rehydrate_enums(schema)}
    end
  end

  @doc """
  Normalizes and validates params with the action's own `validate_params/1`.

  Never executes the action.
  """
  @spec validate(module(), map()) :: {:ok, map()} | {:error, term()}
  def validate(module, params) when is_atom(module) and is_map(params) do
    with :ok <- ensure_loaded(module),
         :ok <- ensure_validatable(module),
         {:ok, normalized} <- normalize(module, params) do
      module.validate_params(normalized)
    end
  end

  @doc """
  Normalizes params and runs the action through `Jido.Exec.run/4`.

  Returns Jido's result envelope unchanged.
  """
  @spec execute(module(), map(), map(), keyword()) :: term()
  def execute(module, params, context \\ %{}, opts \\ [])
      when is_atom(module) and is_map(params) do
    case invocation(context) do
      nil -> execute_action(module, params, context, opts)
      invocation -> execute_traced(module, params, context, opts, invocation)
    end
  end

  defp execute_action(module, params, context, opts) do
    with {:ok, normalized} <- normalize(module, params) do
      Jido.Exec.run(module, normalized, context, opts)
    end
  end

  defp execute_traced(module, params, context, opts, invocation) do
    started = System.monotonic_time(:millisecond)
    context = Map.merge(context, Map.take(invocation, [:tool_call_id, :tool_invocation_path]))
    emit(invocation, module, :tool_started, %{arguments: params})

    try do
      result = execute_action(module, params, context, opts)
      complete(invocation, module, result, started)
      result
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        complete(invocation, module, {:error, %{exception_kind: kind}}, started)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp invocation(%{tool_call_id: id} = context) when is_binary(id) and byte_size(id) > 0 do
    path = Map.get(context, :tool_invocation_path, [id])

    with true <- valid_path?(path, id),
         {callback, artifacts?} <- destination(context) do
      child_path = path ++ [Ecto.UUID.generate()]

      %{
        tool_call_id: path_id(child_path),
        tool_invocation_path: child_path,
        parent_id: id,
        request_id: Map.get(context, :request_id) || hd(path),
        run_id: Map.get(context, :run_id) || hd(path),
        callback: callback,
        artifacts?: artifacts?
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp invocation(_context), do: nil

  defp valid_path?([root | segments] = path, id) when is_binary(root) and root != "" do
    Enum.all?(segments, &match?({:ok, _}, Ecto.UUID.cast(&1))) and path_id(path) == id
  end

  defp valid_path?(_path, _id), do: false

  defp path_id([root]), do: root

  defp path_id([root | segments]),
    do: Enum.join(["zaq", Base.url_encode64(root, padding: false) | segments], ".")

  defp destination(%{on_tool_event: callback}) when is_function(callback, 1),
    do: {callback, false}

  defp destination(%{on_tool_event: callback}) when not is_nil(callback), do: nil

  defp destination(%{tool_event_sink: {:pid, pid}, request_id: request, run_id: run})
       when is_pid(pid) and is_binary(request) and is_binary(run),
       do: {fn event -> RequestStream.send_event({:pid, pid}, event) end, true}

  defp destination(_context), do: nil

  defp complete(invocation, module, result, started) do
    {outcome, evidence} = result_evidence(result)

    emit(invocation, module, :tool_completed, %{
      result: evidence,
      outcome: outcome,
      duration_ms: max(System.monotonic_time(:millisecond) - started, 0)
    })
  end

  defp result_evidence({:ok, payload}), do: {"succeeded", {:ok, payload, []}}
  defp result_evidence({:error, reason}), do: {"failed", {:error, reason, []}}
  defp result_evidence({:ok, _, _} = result), do: {"succeeded", result}
  defp result_evidence({:error, _, _} = result), do: {"failed", result}
  defp result_evidence(result), do: {"unknown", result}

  defp emit(invocation, module, kind, data) do
    data =
      data
      |> Map.new(fn {key, value} ->
        # Arguments never carry artifact bytes, even on the agent route.
        {key, trace_value(value, key == :result and invocation.artifacts?, 0)}
      end)
      |> Map.merge(%{
        invocation_path: invocation.tool_invocation_path,
        parent_id: invocation.parent_id,
        origin: "zaq_action"
      })

    event =
      Event.new(%{
        kind: kind,
        seq: 0,
        iteration: 0,
        request_id: invocation.request_id,
        run_id: invocation.run_id,
        tool_call_id: invocation.tool_call_id,
        tool_name: action_name(module),
        data: data
      })

    case invocation.callback.(event) do
      {:error, _} -> trace_failure()
      _ -> :ok
    end
  rescue
    _ -> trace_failure()
  catch
    _, _ -> trace_failure()
  end

  defp action_name(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0),
      do: module.name(),
      else: Atom.to_string(module)
  end

  defp trace_failure, do: Logger.warning("Nested Action trace delivery failed")

  # Keep only the supported artifact shapes on the default runtime route. A
  # custom callback (including workflow storage) receives metadata, never bytes.
  defp trace_value(_value, _artifacts?, depth) when depth >= 16, do: "[omitted]"

  defp trace_value(%Record{} = record, artifacts?, depth) do
    fields =
      record
      |> Record.metadata()
      # The metadata contract owns this allowlist; its keys are existing Record fields.
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.merge(%{content: nil, materialization_handle: nil, provenance_ref: nil})

    safe = trace_map(fields, artifacts?, depth)
    if artifacts?, do: %{struct(Record, safe) | content: record.content}, else: safe
  end

  defp trace_value(%ToolResult{} = result, artifacts?, depth) do
    fields = result |> Map.from_struct() |> Map.put(:content, nil) |> trace_map(artifacts?, depth)
    if artifacts?, do: struct(ToolResult, fields), else: fields
  end

  defp trace_value(%ContentPart{} = part, true, depth) do
    fields = part |> Map.from_struct() |> Map.put(:data, nil) |> trace_map(false, depth)
    %{struct(ContentPart, fields) | data: part.data}
  end

  defp trace_value(%ContentPart{} = part, false, depth),
    do: part |> Map.from_struct() |> Map.drop([:data, :url]) |> trace_map(false, depth)

  defp trace_value(%_{} = value, _artifacts?, _depth),
    do: ToolError.trace_summary(value)

  defp trace_value(value, artifacts?, depth) when is_map(value),
    do: trace_map(value, artifacts?, depth)

  defp trace_value(value, artifacts?, depth) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.map(&trace_value(&1, artifacts?, depth + 1))
      |> List.to_tuple()

  defp trace_value(value, artifacts?, depth) when is_list(value),
    do: value |> Enum.take(100) |> Enum.map(&trace_value(&1, artifacts?, depth + 1))

  defp trace_value(value, _artifacts?, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value), do: value

  defp trace_value(value, _artifacts?, _depth) when is_binary(value) do
    if String.valid?(value),
      do: Observe.sanitize_transport_payload(value),
      else: "[binary omitted]"
  end

  defp trace_value(_value, _artifacts?, _depth), do: "[runtime value omitted]"

  defp trace_map(map, artifacts?, depth) do
    map
    |> Enum.take(100)
    |> Map.new(fn {key, _value} ->
      capability? =
        key in [
          :materialization_handle,
          "materialization_handle",
          :provenance_ref,
          "provenance_ref"
        ]

      {key, if(capability?, do: "[REDACTED]", else: nil)}
    end)
    |> Observe.sanitize_sensitive()
    |> Map.new(fn {key, redaction} ->
      value =
        if is_nil(redaction),
          do: trace_value(Map.get(map, key), artifacts?, depth + 1),
          else: redaction

      {key, value}
    end)
  end

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:invalid_action, module, reason}}
    end
  end

  defp ensure_validatable(module) do
    if function_exported?(module, :validate_params, 1),
      do: :ok,
      else: {:error, {:invalid_action, module, :missing_validate_params}}
  end

  defp rehydrate_enums(params, schema) do
    enums = atom_enums(schema, ActionSchema.schema_type(schema))

    Map.new(params, fn
      {key, value} when is_atom(key) and is_binary(value) ->
        {key, rehydrate(value, Map.get(enums, key))}

      pair ->
        pair
    end)
  end

  defp rehydrate(value, allowed) when is_list(allowed) do
    Enum.find(allowed, value, &(is_atom(&1) and Atom.to_string(&1) == value))
  end

  defp rehydrate(value, _allowed), do: value

  # Returns %{field => allowed_atoms_and_other_values} for top-level enum fields.
  defp atom_enums(schema, :nimble) do
    for {key, opts} <- schema,
        is_list(opts),
        {:in, allowed} <- [opts[:type]],
        is_list(allowed),
        into: %{} do
      {key, allowed}
    end
  end

  defp atom_enums(%{fields: fields}, :zoi) when is_list(fields) or is_map(fields) do
    for {key, field} <- fields, is_atom(key), allowed = zoi_atom_enum(field), into: %{} do
      {key, allowed}
    end
  end

  defp atom_enums(_schema, _type), do: %{}

  defp zoi_atom_enum(%Zoi.Types.Enum{enum_type: :atom, values: values}),
    do: Enum.map(values, fn {key, _value} -> key end)

  defp zoi_atom_enum(%{inner: %_{} = inner}), do: zoi_atom_enum(inner)
  defp zoi_atom_enum(_other), do: nil
end
