defmodule Zaq.Agent.Tools.Workflow.LuaEval do
  @moduledoc """
  Workflow adapter for the existing sandboxed `Jido.Tools.LuaEval` Action.

  `code` evaluates with the supplied `data` available as the Lua global `data`.
  Only the first returned value is exposed, under `result`. Execution delegates
  through `Jido.Exec` and retains the upstream sandbox, heap limit and deadline
  handling. `eval_timeout_ms` controls the upstream evaluation timeout; it is
  separate from the workflow runner's reserved `timeout_ms` parameter.

  With `include_context: true`, two additional globals are available: `input`
  is the current Action input (for example a Batch item), and `request` is the
  workflow's original input from `source_event.assigns.input`. Event triggers
  store their payload there; `source_event.request` is trigger metadata. Outside
  a persisted workflow, `request` falls back to `context.source_request`. This
  exposes payload data, not actor or permission context. The default keeps only
  the explicit `data` global.

  With `merge_result: true`, a returned object also exposes its fields as
  top-level Action outputs, for supplying a following Action's params. Known
  field names use existing atoms; other names remain strings. No new atoms are
  created. Engine-control fields are rejected and `result` remains the complete
  normalized return value. By default only `result` is returned.

  Lua returns tables as lists of key/value pairs. Contiguous numeric keys 1..N
  become ordered Elixir lists; other keys become maps. Conversion is recursive.
  Empty tables become empty lists because Lua does not distinguish an empty
  array from an empty object. Scalars and nil retain their values. Lua's normal
  table semantics apply, including nil removing a table entry.

  This adapter satisfies the workflow Action contract. It is not registered as
  an additional agent tool; agents retain the existing `advanced.lua_eval` tool.

  ## Example

      Jido.Exec.run(
        Zaq.Agent.Tools.Workflow.LuaEval,
        %{code: "return {answer = data.value + 1}", data: %{value: 41}},
        %{}
      )
      # => {:ok, %{result: %{"answer" => 42}}}
  """

  alias Zaq.Engine.Workflows
  alias Zaq.MapUtils

  use Zaq.Engine.Workflows.Action,
    name: "workflow_lua_eval",
    description: "Evaluate sandboxed Lua with data and return normalized lists, maps or scalars.",
    schema: [
      code: [
        type: :string,
        required: true,
        doc: "Lua code; its first return value becomes result."
      ],
      data: [type: :any, default: %{}, doc: "Value exposed through the Lua global data."],
      input: [
        type: :any,
        required: false,
        doc: "Current item, exposed when include_context is true."
      ],
      include_context: [
        type: :boolean,
        default: false,
        doc: "Expose the current input and original workflow request as Lua globals."
      ],
      merge_result: [
        type: :boolean,
        default: false,
        doc: "Also expose returned object fields as params for a following Action."
      ],
      eval_timeout_ms: [
        type: :pos_integer,
        default: 1000,
        doc: "Lua evaluation timeout in milliseconds."
      ]
    ],
    output_schema: [
      result: [
        type: :any,
        required: true,
        doc: "First returned value, with Lua tables normalized."
      ]
    ]

  @impl Jido.Action
  def run(%{code: code} = params, context) do
    lua_params = %{
      code: code,
      globals: globals(params, context),
      return_mode: :first,
      timeout_ms: Map.get(params, :eval_timeout_ms, 1000)
    }

    with {:ok, %{result: result}} <-
           Jido.Exec.run(Jido.Tools.LuaEval, lua_params, context, max_retries: 0) do
      result |> normalize() |> output(Map.get(params, :merge_result, false))
    end
  end

  defp globals(params, context) do
    data = %{data: Map.get(params, :data, %{})}

    if Map.get(params, :include_context, false) do
      Map.merge(data, %{
        input: Map.get(params, :input),
        request: workflow_request(context)
      })
    else
      data
    end
  end

  defp workflow_request(%{run_id: run_id} = context) when is_binary(run_id) do
    case Workflows.get_run(run_id) do
      %{source_event: %{assigns: assigns}} when is_map(assigns) ->
        case MapUtils.fetch_either(assigns, :input, "input") do
          nil -> Map.get(context, :source_request)
          input -> input
        end

      _ ->
        Map.get(context, :source_request)
    end
  end

  defp workflow_request(context), do: Map.get(context, :source_request)

  defp output(result, false), do: {:ok, %{result: result}}

  defp output(result, true) when is_map(result) do
    if Enum.all?(Map.keys(result), &output_key?/1) do
      fields = Map.new(result, fn {key, value} -> {existing_key(key), value} end)
      {:ok, Map.put(fields, :result, result)}
    else
      {:error, "merge_result requires named fields without workflow engine-control keys"}
    end
  end

  defp output(_result, true), do: {:error, "merge_result requires a returned object"}

  defp output_key?(key) when is_binary(key) do
    not String.starts_with?(key, "__") and
      key not in ["wrapped_module", "run_id", "step_name", "step_index", "timeout_ms"]
  end

  defp output_key?(_key), do: false

  defp existing_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize([]), do: []

  defp normalize(entries) when is_list(entries) do
    keys = Enum.map(entries, fn {key, _value} -> key end)

    if Enum.sort(keys) == Enum.to_list(1..length(entries)) do
      entries
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {_key, value} -> normalize(value) end)
    else
      Map.new(entries, fn {key, value} -> {key, normalize(value)} end)
    end
  end

  defp normalize(value), do: value
end
