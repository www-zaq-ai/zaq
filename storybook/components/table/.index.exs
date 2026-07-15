defmodule Storybook.Components.Table do
  use PhoenixStorybook.Index

  def folder_name, do: "Table"
  def folder_index, do: 5

  def entry("table"), do: [name: "Table", index: 1]
  def entry("empty_state"), do: [name: "Empty State", index: 2]
  def entry(_), do: []
end
