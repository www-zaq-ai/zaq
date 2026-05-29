defmodule Storybook.Semantic do
  use PhoenixStorybook.Index

  def folder_name, do: "Semantics"
  def folder_index, do: 1

  def entry("text_styles_deprecated"),
    do: [name: "Text Styles deprecated ⚠"]
end
