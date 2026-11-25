defmodule Zaq.Materialization.RowsMarkdownTest do
  use ExUnit.Case, async: true

  alias Zaq.Materialization.RowsMarkdown

  defp incremental(rows) do
    {iodata, state} =
      Enum.reduce(rows, {[], RowsMarkdown.new()}, fn row, {acc, state} ->
        {part, state} = RowsMarkdown.push(state, row)
        {[acc | part], state}
      end)

    IO.iodata_to_binary([iodata | RowsMarkdown.done(state)])
  end

  describe "render/1" do
    test "no rows render nothing" do
      assert RowsMarkdown.render([]) == ""
    end

    test "maps become a table whose columns are the first row's keys" do
      rows = [%{"b" => 1, "a" => "x"}, %{"a" => true, "c" => "ignored"}, %{"b" => nil}]

      assert RowsMarkdown.render(rows) ==
               "| a | b |\n| --- | --- |\n| x | 1 |\n| true |  |\n|  |  |"
    end

    test "nested atom-keyed values are rendered as JSON" do
      rows = [%{"a" => [1, %{b: nil}], "c" => %{"d" => 1.5}}]

      assert RowsMarkdown.render(rows) ==
               ~s(| a | c |\n| --- | --- |\n| [1,{"b":null}] | {"d":1.5} |)
    end

    test "rows that are not maps are one line each" do
      assert RowsMarkdown.render(["x", 2, nil, [1], :atom]) == "x\n2\n\n[1]\natom"
    end

    test "a later non-map row in a table raises, as the original conversion did" do
      assert_raise Protocol.UndefinedError, fn -> RowsMarkdown.render([%{"a" => 1}, 7]) end

      assert_raise Protocol.UndefinedError, fn ->
        {_, state} = RowsMarkdown.push(RowsMarkdown.new(), %{"a" => 1})
        RowsMarkdown.push(state, "text")
      end
    end
  end

  describe "incremental rendering" do
    test "matches render/1 for every shape" do
      for rows <- [
            [],
            [%{"a" => 1}],
            [%{"b" => 1, "a" => "x"}, %{"a" => true}, %{"b" => nil}],
            ["x", 2, nil, [1, 2], %{"k" => "v"}],
            [%{"a" => "é😀|"}, %{"a" => %{"n" => [nil, 1.0]}}]
          ] do
        assert incremental(rows) == RowsMarkdown.render(rows)
      end
    end

    test "counts rows" do
      state = Enum.reduce([1, 2, 3], RowsMarkdown.new(), &elem(RowsMarkdown.push(&2, &1), 1))
      assert state.rows == 3
    end
  end
end
