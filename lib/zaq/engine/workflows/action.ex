defmodule Zaq.Engine.Workflows.Action do
  @moduledoc """
  Contract every `action` / `agent` node module must satisfy to be usable as a
  workflow step.

  A workflow action is a `Jido.Action` (for `run/2`, parameter validation, and
  the `schema` / `output_schema` introspection) that *additionally* declares
  this behaviour. The idiomatic way is a single `use` call — this macro wraps
  `use Jido.Action`, attaches the behaviour with default `on_success/2` /
  `on_failure/2`, and enforces the contract at compile time:

      defmodule MyAction do
        use Zaq.Engine.Workflows.Action,
          name: "my_action",
          schema: [input: [type: :any, required: true]],
          output_schema: [result: [type: :map, required: true]]

        @impl Jido.Action
        def run(params, ctx), do: {:ok, %{result: params}}
      end

  A bare `use Zaq.Engine.Workflows.Action` (no options) is also supported for
  modules that declare their own `use Jido.Action` separately (e.g. some test
  fixtures and infrastructure steps): it attaches only the behaviour, default
  hooks, and log helpers, and performs **no** compile-time enforcement.

  ## The contract

  A conforming module must:

  - export `on_success/2` and `on_failure/2` (always provided by this macro)
  - declare a **non-empty** input `schema/0` (provided by `use Jido.Action`)
  - declare a **non-empty** `output_schema/0` (provided by `use Jido.Action`)

  The workflow engine does **not** call `on_success/2` / `on_failure/2` itself —
  the contract only guarantees the module exposes them so callers and tooling
  can rely on their presence. DAG routing remains driven by edges and
  conditions.

  ## Enforcement

  When the macro is used with options (the full-mode declaration), the contract
  is enforced at **compile time**: a missing/empty `schema` or `output_schema`
  raises a `CompileError`. As a runtime backstop, `DagBuilder.build/2` also calls
  `validate/1` for every `action` / `agent` node and refuses to build the DAG
  when a module does not conform, returning
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
  modules that only `alias` this module (e.g. `StepRunner`).
  """

  @doc """
  Turns the calling module into a workflow action.

  This wraps `use Jido.Action` (forwarding all options — `name`, `schema`,
  `output_schema`, etc.), injects `@behaviour Zaq.Engine.Workflows.Action` with
  overridable default `on_success/2` / `on_failure/2`, and imports the log
  helpers. The macro also enforces the contract at **compile time**: the `use`
  options must declare a non-empty `schema` and `output_schema`, otherwise the
  module fails to compile with a descriptive error. (`on_success/2` /
  `on_failure/2` are always provided by this macro, so they cannot be missing.)

  Modules declare everything in one `use` call:

      use Zaq.Engine.Workflows.Action,
        name: "my_action",
        schema: [input: [type: :any, required: true]],
        output_schema: [result: [type: :map, required: true]]

      @impl Jido.Action
      def run(params, _ctx), do: {:ok, %{result: params}}

  Modules that want custom lifecycle hooks override after calling `use`:

      @impl Zaq.Engine.Workflows.Action
      def on_failure(error, _ctx) do
        Logger.warning("step failed: \#{inspect(error)}")
        :ok
      end
  """
  defmacro __using__(opts) do
    if opts == [] do
      # Legacy / behaviour-only mode: the module declares its own
      # `use Jido.Action, ...` separately. We only attach the behaviour, default
      # lifecycle hooks, and log helpers. No `use Jido.Action`, no contract
      # enforcement (the runtime `validate/1` backstop still applies at DAG build).
      behaviour_quote()
    else
      # Full mode: this macro IS the action declaration. Forward the options to
      # `use Jido.Action` and enforce the contract at compile time.
      enforce_contract_opts!(opts, __CALLER__)

      quote do
        use Jido.Action, unquote(opts)
        unquote(behaviour_quote())
      end
    end
  end

  defp behaviour_quote do
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

  # Compile-time contract enforcement on the `use` options.
  #
  # The options passed to `use` are a literal keyword list for every workflow
  # action in this codebase, so `schema` / `output_schema` can be inspected at
  # macro-expansion time — before the module finishes compiling — and a
  # `CompileError` raised for any non-conforming declaration. When an option is
  # not a compile-time literal (e.g. `schema: @my_schema`) the static check is
  # skipped and `validate/1` (called by `DagBuilder.build/2`) remains the
  # runtime backstop.
  defp enforce_contract_opts!(opts, caller) do
    if Keyword.keyword?(opts) do
      Enum.each([:schema, :output_schema], &check_schema_opt!(opts, &1, caller))
    end
  end

  defp check_schema_opt!(opts, key, caller) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_list(value) ->
        if value == [], do: raise_contract_error(key, "is empty", caller)

      {:ok, _non_literal} ->
        # Non-literal AST (e.g. a module attribute) — defer to runtime validate/1.
        :ok

      :error ->
        raise_contract_error(key, "is missing", caller)
    end
  end

  defp raise_contract_error(key, problem, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "Zaq.Engine.Workflows.Action contract violation: `#{key}` #{problem}. " <>
          "Every workflow action must declare a non-empty `schema` and `output_schema`."
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
  Resolves a node's `"module"` string and validates the resulting module against
  the action contract — the single source of truth for save-time node validation
  (`Step.Node.changeset`) and run-time DAG building (`DagBuilder`).

  Returns `:ok`, `{:error, {:unknown_module, ref}}` when `ref` is `nil` or names
  no loadable module, or `{:error, {:contract_violation, module, missing}}` when
  the module loads but does not conform (see `validate/1`).
  """
  @spec validate_ref(String.t() | nil) ::
          :ok
          | {:error, {:unknown_module, String.t() | nil}}
          | {:error, {:contract_violation, module(), [missing()]}}
  def validate_ref(nil), do: {:error, {:unknown_module, nil}}

  def validate_ref(ref) when is_binary(ref) do
    case resolve(ref) do
      {:ok, module} -> validate(module)
      {:error, _} = err -> err
    end
  end

  @doc """
  Resolves a node's `"module"` string to a loaded module atom.

  Returns `{:ok, module}` or `{:error, {:unknown_module, ref}}`. Does not check
  the action contract — use `validate_ref/1` for that.
  """
  @spec resolve(String.t() | nil) ::
          {:ok, module()} | {:error, {:unknown_module, String.t() | nil}}
  def resolve(nil), do: {:error, {:unknown_module, nil}}

  def resolve(ref) when is_binary(ref) do
    module = ref |> String.split(".") |> Module.concat()

    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      {:error, _} -> {:error, {:unknown_module, ref}}
    end
  end

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
