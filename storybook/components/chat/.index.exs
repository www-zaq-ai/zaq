defmodule Storybook.Components.Chat do
  @moduledoc """
  BO chat **page** slices from `ZaqWeb.Chat` (sidebar, transcript, composer, modals).

  Message **atoms** (`ZaqWeb.Components.ChatMessage`) are under **Components → Chat message**.
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Chat"
  def folder_index, do: 3
end
