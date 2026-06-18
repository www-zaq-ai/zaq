defmodule Storybook.Semantic do
  use PhoenixStorybook.Index

  def folder_name, do: "Semantics"
  def folder_index, do: 2

  def entry("text_styles_deprecated"),
    do: [name: "Text Styles deprecated ⚠"]

  def entry("colors_deprecated"),
    do: [name: "Colors deprecated ⚠"]
end
