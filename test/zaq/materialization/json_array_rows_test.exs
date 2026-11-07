defmodule Zaq.Materialization.JsonArrayRowsTest do
  use ExUnit.Case, async: true

  alias Zaq.Materialization.{JsonArrayRows, RowsMarkdown}

  @bodies [
    "[]",
    " \n[ ] \n",
    ~s([{"a":1},{"a":2}]),
    ~s([{"b":1,"a":"x|y","n":null},{"a":[1,{"z":null}],"c":true,"b":2.5},{"a":"\\u00e9\\ud83d\\ude00"}]),
    ~s([1,"two",null,[3,[4]],{"k":{"deep":[true,false]}}]),
    ~s([{"a":"é😀 raw utf-8","b":-0.5e3,"c":12345678901234567890}])
  ]

  defp run(body, sizes, max_element_bytes \\ 1_000_000) do
    {:ok, out} = Agent.start_link(fn -> [] end)
    emit = fn iodata -> Agent.update(out, &[iodata | &1]) end

    state = JsonArrayRows.new(emit, max_element_bytes)

    result =
      body
      |> chunks(sizes)
      |> Enum.reduce_while({:ok, state}, fn chunk, {:ok, state} ->
        case JsonArrayRows.feed(state, chunk) do
          {:ok, state} -> {:cont, {:ok, state}}
          error -> {:halt, error}
        end
      end)

    result =
      case result do
        {:ok, state} -> JsonArrayRows.finish(state)
        error -> error
      end

    rendered = out |> Agent.get(& &1) |> Enum.reverse() |> IO.iodata_to_binary()
    {result, rendered}
  end

  defp chunks(body, :whole), do: [body]

  defp chunks(body, size),
    do:
      body
      |> :binary.bin_to_list()
      |> Enum.chunk_every(size)
      |> Enum.map(&:erlang.list_to_binary/1)

  describe "rendering" do
    test "equals the conversion of the decoded array, however the body is split" do
      for body <- @bodies, sizes <- [:whole, 1, 2, 3, 7] do
        expected = body |> Jason.decode!() |> RowsMarkdown.render()

        assert {{:ok, state}, rendered} = run(body, sizes)
        # The writer receives each row separately, so the joined output is the whole table.
        assert rendered == expected, "body #{inspect(body)} in #{inspect(sizes)}-byte pieces"
        assert JsonArrayRows.rows(state) == body |> Jason.decode!() |> length()
      end
    end

    test "rows are emitted one by one while the body is still arriving" do
      {:ok, out} = Agent.start_link(fn -> [] end)
      state = JsonArrayRows.new(fn iodata -> Agent.update(out, &[iodata | &1]) end, 1_000)

      {:ok, state} = JsonArrayRows.feed(state, ~s([{"a":1},{"a":2},{"a":))
      assert Agent.get(out, &length/1) == 2
      {:ok, state} = JsonArrayRows.feed(state, ~s(3}]))
      assert Agent.get(out, &length/1) == 3
      assert {:ok, _} = JsonArrayRows.finish(state)
    end
  end

  describe "invalid input" do
    test "an empty input and a non-array value are rejected" do
      state = JsonArrayRows.new(fn _ -> :ok end, 100)
      assert {:error, :invalid_json} = JsonArrayRows.finish(state)
      assert {:error, :invalid_json} = JsonArrayRows.feed(state, "{}")
    end

    test "malformed, truncated and trailing JSON are rejected" do
      for body <- [~s([{"a":1},{"a"), "[1,", "[1] x", "[1][2]", "[1,]", ~s(["bad\\q"])] do
        assert {{:error, :invalid_json}, _} = run(body, 2), inspect(body)
      end
    end

    test "trailing whitespace is fine" do
      assert {{:ok, _}, "1"} = run("[1] \n\t", 1)
    end

    test "an emit failure stops decoding with its reason" do
      state = JsonArrayRows.new(fn _ -> {:error, {:materialization_limit, 5}} end, 1_000)
      assert {:error, {:materialization_limit, 5}} = JsonArrayRows.feed(state, "[1,2]")
    end
  end

  describe "memory bound" do
    test "one element larger than the bound is rejected" do
      big = ~s([{"a":"#{String.duplicate("x", 500)}"}])
      assert {{:error, {:materialization_limit, 100}}, _} = run(big, 40, 100)
    end

    test "many rows far larger than the bound in total are accepted" do
      row = ~s({"a":"#{String.duplicate("x", 30)}"})
      body = "[" <> Enum.join(List.duplicate(row, 2_000), ",") <> "]"

      assert byte_size(body) > 50 * 100
      assert {{:ok, state}, _} = run(body, 64, 200)
      assert JsonArrayRows.rows(state) == 2_000
    end
  end
end
