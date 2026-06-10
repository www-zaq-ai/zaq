defmodule Zaq.Engine.Workflows.Action do
  @moduledoc """
  Contract every `action` / `agent` node module must satisfy to be usable as a
  workflow step.

  A workflow action is a `Jido.Action` (it still `use Jido.Action` for `run/2`,
  parameter validation, and the `schema` / `output_schema` introspection) that
  *additionally* declares this behaviour:

      defmodule MyAction do
        use Jido.Action,
          name: "my_action",
          schema: [input: [type: :any, required: true]],
          output_schema: [result: [type: :map, required: true]]

        @behaviour Zaq.Engine.Workflows.Action

        @impl Jido.Action
        def run(params, ctx), do: {:ok, %{result: params}}

        @impl Zaq.Engine.Workflows.Action
        def on_success(result, _ctx), do: {:ok, result}

        @impl Zaq.Engine.Workflows.Action
        def on_failure(_error, _ctx), do: :ok
      end

  ## The contract

  A conforming module must:

  - export `on_success/2` and `on_failure/2`
  - declare a **non-empty** input `schema/0` (provided by `use Jido.Action`)
  - declare a **non-empty** `output_schema/0` (provided by `use Jido.Action`)

  The workflow engine does **not** call `on_success/2` / `on_failure/2` itself —
  the contract only guarantees the module exposes them so callers and tooling
  can rely on their presence. DAG routing remains driven by edges and
  conditions.

  ## Enforcement

  `DagBuilder.build/2` calls `validate/1` for every `action` / `agent` node and
  refuses to build the DAG when a module does not conform, returning
  `{:error, {:contract_violation, module, missing}}` where `missing` is a subset
  of `[:on_success, :on_failure, :schema, :output_schema]`.

  Edge guard nodes (`Steps.EdgeStep`) are infrastructure and are intentionally
  **not** subject to this contract.

  ## Log helpers

  Two helpers are available for building structured, timestamped log entries
  inside action `run/2` implementations:

      def run(params, _ctx) do
        t0 = log_start()
        # ... do work ...
        log = log_entry(:chunk_completed, t0, %{index: 0, results: 3})
        {:ok, result, logs: [log]}
      end

  - `log_start/0` — captures a monotonic millisecond timestamp.
  - `log_entry(event, t0, attrs \\\\ %{})` — builds a `%{event, at, duration_ms}`
    map merged with `attrs`. Base keys (`event`, `at`, `duration_ms`) are never
    overridden by caller-supplied `attrs`.

  Both helpers are imported automatically by `use Zaq.Engine.Workflows.Action`
  and are also available as `Action.log_start/0` / `Action.log_entry/3` for
  modules that only `alias` this module (e.g. `ActionWrapper`).
  """

  @doc """
  Injects `@behaviour Zaq.Engine.Workflows.Action` and provides overridable
  default implementations of `on_success/2` and `on_failure/2`.

  Modules that want custom lifecycle hooks simply override after calling `use`:

      use Zaq.Engine.Workflows.Action

      @impl Zaq.Engine.Workflows.Action
      def on_failure(error, _ctx) do
        Logger.warning("step failed: \#{inspect(error)}")
        :ok
      end
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Zaq.Engine.Workflows.Action

      import Zaq.Engine.Workflows.Action, only: [log_start: 0, log_entry: 2, log_entry: 3]

      @impl Zaq.Engine.Workflows.Action
      def on_success(result, _context), do: {:ok, result}

      @impl Zaq.Engine.Workflows.Action
      def on_failure(_error, _context), do: :ok

      defoverridable on_success: 2, on_failure: 2
    end
  end

  @doc """
  Returns a monotonic millisecond timestamp for use as the `t0` argument to
  `log_entry/3`. Call this immediately before the work you want to time.
  """
  @spec log_start() :: integer()
  def log_start, do: System.monotonic_time(:millisecond)

  @doc """
  Builds a standardised timestamped log entry map.

  - `event` — atom or string label; atoms are converted to strings.
  - `t0` — value returned by `log_start/0`.
  - `attrs` — optional extra fields merged into the entry (e.g. `%{index: 0}`).

  The base keys `event`, `at`, and `duration_ms` are always set from the
  arguments and **cannot be overridden** by `attrs`.

  Returns a map of the form:

      %{event: "chunk_completed", at: ~U[...], duration_ms: 42, index: 0}
  """
  @spec log_entry(atom() | String.t(), integer(), map()) :: map()
  def log_entry(event, t0, attrs \\ %{}) do
    Map.new(attrs)
    |> Map.merge(%{
      event: to_string(event),
      at: DateTime.utc_now(),
      duration_ms: System.monotonic_time(:millisecond) - t0
    })
  end

  @typedoc "A piece of the contract a module failed to satisfy."
  @type missing :: :on_success | :on_failure | :schema | :output_schema

  @doc """
  Invoked by callers after the action's `run/2` returns successfully.

  Receives the action's result map and the execution context. The return value
  is advisory — the engine does not currently consume it.
  """
  @callback on_success(result :: map(), context :: map()) ::
              :ok | {:ok, map()} | {:error, term()}

  @doc """
  Invoked by callers after the action's `run/2` fails or raises.

  Receives the failure reason and the execution context.
  """
  @callback on_failure(error :: term(), context :: map()) :: :ok | {:error, term()}

  @required_pieces [:on_success, :on_failure, :schema, :output_schema]

  @doc """
  Inspects the input schema of `module` and returns the field name and delivery
  mode Batch / Iterate should use when sending chunk data to this action.

  Rules (applied to required fields only):

  - Exactly one required `:list` or `{:list, _}` field → `{:ok, {field, :list}}`
  - Zero list fields, exactly one required non-list field → `{:ok, {field, :item}}`
  - One list field + any number of non-list required fields → list wins; `{:ok, {field, :list}}`
  - Zero required fields → `{:error, {:no_batch_field, module}}`
  - Multiple list fields → `{:error, {:ambiguous_batch_field, module, fields}}`
  - Zero list fields, multiple non-list required fields → `{:error, {:ambiguous_batch_field, module, fields}}`
  """
  @spec batch_field(module()) ::
          {:ok, {field :: atom(), mode :: :list | :item}}
          | {:error, {:no_batch_field, module()}}
          | {:error, {:ambiguous_batch_field, module(), [atom()]}}
  def batch_field(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> detect_batch_field(module)
      {:error, _} -> {:error, {:no_batch_field, module}}
    end
  end

  defp detect_batch_field(module) do
    if function_exported?(module, :schema, 0) do
      module.schema()
      |> Enum.filter(fn {_field, opts} -> opts[:required] == true end)
      |> classify_batch_fields(module)
    else
      {:error, {:no_batch_field, module}}
    end
  end

  defp classify_batch_fields(required_fields, module) do
    {list_fields, item_fields} =
      Enum.split_with(required_fields, fn {_field, opts} -> list_type?(opts[:type]) end)

    names = fn fields -> Enum.map(fields, fn {f, _} -> f end) end

    case {list_fields, item_fields} do
      {[], []} -> {:error, {:no_batch_field, module}}
      {[{field, _}], _} -> {:ok, {field, :list}}
      {[], [{field, _}]} -> {:ok, {field, :item}}
      {[], multiple} -> {:error, {:ambiguous_batch_field, module, names.(multiple)}}
      {multiple, _} -> {:error, {:ambiguous_batch_field, module, names.(multiple)}}
    end
  end

  defp list_type?(:list), do: true
  defp list_type?({:list, _}), do: true
  defp list_type?(_), do: false

  @doc """
  Validates that `module` satisfies the workflow action contract.

  Returns `:ok` for a conforming module, or
  `{:error, {:contract_violation, module, missing}}` where `missing` is a
  non-empty, ordered subset of `#{inspect(@required_pieces)}`.

  The module is loaded with `Code.ensure_loaded/1` first, so this is safe to
  call on a module that has not yet been referenced at runtime.
  """
  @spec validate(module()) :: :ok | {:error, {:contract_violation, module(), [missing()]}}
  def validate(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        case missing_pieces(module) do
          [] -> :ok
          missing -> {:error, {:contract_violation, module, missing}}
        end

      {:error, _} ->
        {:error, {:contract_violation, module, @required_pieces}}
    end
  end

  defp missing_pieces(module) do
    Enum.reject(@required_pieces, &satisfies?(module, &1))
  end

  defp satisfies?(module, :on_success), do: function_exported?(module, :on_success, 2)
  defp satisfies?(module, :on_failure), do: function_exported?(module, :on_failure, 2)
  defp satisfies?(module, :schema), do: non_empty_schema?(module, :schema)
  defp satisfies?(module, :output_schema), do: non_empty_schema?(module, :output_schema)

  defp non_empty_schema?(module, fun) do
    function_exported?(module, fun, 0) and apply(module, fun, []) not in [nil, []]
  end
end
