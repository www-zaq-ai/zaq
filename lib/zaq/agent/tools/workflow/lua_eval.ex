defmodule Zaq.Agent.Tools.Workflow.LuaEval do
  @moduledoc """
  Workflow adapter for the existing sandboxed `Jido.Tools.LuaEval` Action.

  `code` evaluates with the supplied `data` available as the Lua global `data`.
  Only the first returned value is exposed, under `result`. Execution delegates
  through `Jido.Exec` and retains the upstream sandbox, heap limit and deadline
  handling. `eval_timeout_ms` controls the upstream evaluation timeout; it is
  separate from the workflow runner's reserved `timeout_ms` parameter.

  Lua receives only the explicit `data` global. Workflow mappings may supply
  individual outputs or the cascade as data; this adapter does not load run state.

  Returns only `result`. Use workflow cascade mappings to supply its fields as
  parameters to following Actions.

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
      globals: %{data: Map.get(params, :data, %{})},
      return_mode: :first,
      timeout_ms: Map.get(params, :eval_timeout_ms, 1000)
    }

    with {:ok, %{result: result}} <-
           Jido.Exec.run(Jido.Tools.LuaEval, lua_params, context, max_retries: 0) do
      {:ok, %{result: normalize(result)}}
    end
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
