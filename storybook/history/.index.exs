defmodule Storybook.History do
  @moduledoc """
  BO conversation history page slices (`ZaqWeb.History.*`).
  """
  use PhoenixStorybook.Index

  def folder_name, do: "History"
  def folder_index, do: 12
end
