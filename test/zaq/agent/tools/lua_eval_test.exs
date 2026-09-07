defmodule Zaq.Agent.Tools.LuaEvalTest do
  use ExUnit.Case, async: true

  test "executes Lua with injected globals through Jido.Exec" do
    assert {:ok, %{results: [42, "ZAQ"]}} =
             Jido.Exec.run(
               Jido.Tools.LuaEval,
               %{
                 code: "local total = quantity * price; return total, string.upper(label)",
                 globals: %{quantity: 6, price: 7, label: "zaq"},
                 # Allow cold VM initialization on busy CI runners; this is not a latency test.
                 timeout_ms: 10_000
               },
               %{}
             )
  end
end
