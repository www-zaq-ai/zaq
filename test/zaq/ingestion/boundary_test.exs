defmodule Zaq.Ingestion.BoundaryTest do
  use ExUnit.Case, async: true

  @forbidden ~r/Zaq\.Storage|FileExplorer|SourcePath/

  test "ingestion does not depend on storage filesystem modules" do
    violations =
      "lib/zaq/ingestion/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, "/storage_entry.ex"))
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
