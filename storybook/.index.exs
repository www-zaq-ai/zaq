defmodule Storybook do
  use PhoenixStorybook.Index

  def entry("_welcome"), do: [index: -1]
end
