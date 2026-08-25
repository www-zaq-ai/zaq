defmodule Zaq.Storage.BoundaryTest do
  use ExUnit.Case, async: true

  @forbidden ~r/Application\.(get_env|fetch_env|put_env|delete_env)/

  test "storage production modules read runtime config through Zaq.Config" do
    violations =
      ["lib/zaq/storage.ex", "lib/zaq/storage/**/*.ex"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _line_number} -> line =~ @forbidden end)
        |> Enum.map(fn {_line, line_number} -> "#{path}:#{line_number}" end)
      end)

    assert violations == []
  end
end
