defmodule Storybook.Foundations do
  use PhoenixStorybook.Index

  def folder_name, do: "Foundation"
  def folder_index, do: 1

  def entry("fonts_deprecated"),
    do: [name: "Fonts deprecated ⚠"]
end
