defmodule Storybook.Components.CoreComponentsDeprecated do
  @moduledoc """
  Legacy `ZaqWeb.CoreComponents` — prefer design-system components under **Components**.
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Core components (deprecated) ⚠"
  def folder_index, do: 100
end
