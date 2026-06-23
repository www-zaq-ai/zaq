defmodule Storybook.Dashboard do
  @moduledoc """
  BO dashboard page slices and related BO pages (`ZaqWeb.Dashboard.*`, `/bo/ai-diagnostics`).
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Dashboard"
  def folder_index, do: 7
end
