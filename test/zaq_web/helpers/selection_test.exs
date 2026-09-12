defmodule ZaqWeb.Helpers.SelectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Helpers.Selection

  property "toggling twice restores membership in either mode" do
    check all(ids <- uniq_list_of(integer(1..100), max_length: 20), id <- integer(1..100)) do
      explicit = Selection.toggle_page(Selection.new(%{}), ids)

      for selection <- [explicit, Selection.all_matching(explicit)] do
        assert selection |> Selection.toggle(id) |> Selection.toggle(id) == selection
      end
    end
  end

  property "page operations preserve off-page selections and counts stay bounded" do
    check all(ids <- uniq_list_of(integer(1..100), max_length: 20), total <- integer(0..100)) do
      selected = Selection.toggle(Selection.new(%{}), 101)
      selected = Selection.toggle_page(selected, ids)
      assert Selection.member?(selected, 101)
      assert Selection.page_state(selected, ids) == if(ids == [], do: :none, else: :all)
      all = selected |> Selection.all_matching() |> Selection.toggle_page(ids)
      assert Selection.count(all, total) in 0..total
      assert Selection.member?(all, 101)
    end
  end

  test "scope changes clear both explicit IDs and all-matching exclusions" do
    selected = Selection.new(%{q: "a"}) |> Selection.toggle(1)
    assert Selection.scope(selected, %{q: "a"}) == selected
    assert Selection.scope(selected, %{q: "b"}) == Selection.new(%{q: "b"})
    all = selected |> Selection.all_matching() |> Selection.toggle(2)
    assert Selection.scope(all, %{}) == Selection.new(%{})
    assert Selection.count(selected, 10) == 1
    assert Selection.count(all, 10) == 9
    assert Selection.page_state(selected, [1, 2]) == :mixed
    assert Selection.page_state(selected, [2]) == :none
    assert Selection.clear(all) == Selection.new(%{q: "a"})
    assert Selection.toggle_page(selected, []) == selected
    assert Selection.toggle_page(selected, [1]) == Selection.new(%{q: "a"})
    assert all |> Selection.toggle_page([2]) |> Selection.member?(2)
  end
end
