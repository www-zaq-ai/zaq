defmodule Storybook.Components.ChatMessage do
  @moduledoc """
  Atoms from `ZaqWeb.Components.ChatMessage` (bubbles, feedback, copy).

  BO chat **page layout** slices (`ZaqWeb.Chat.*`) are documented under **Components → Chat**.
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Chat message"
  def folder_index, do: 2
  def folder_open?, do: false
end
