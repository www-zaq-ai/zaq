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
      re-validate or re-implement them.

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
    with {:ok, normalized} <- normalize(module, params) do
      Jido.Exec.run(module, normalized, context, opts)
    end
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
