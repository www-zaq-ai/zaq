defmodule Storybook.Chat do
  @moduledoc """
  BO chat UI: **`ZaqWeb.Chat`** page slices (header, sidebar, transcript, composer, modals) and
  **`ZaqWeb.Components.ChatMessage`** atoms (bubbles, per-message feedback, copy).
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Chat"
  def folder_index, do: 2

  def entry("feedback_modal"),
    do: [name: "Negative feedback (modal)", index: 20]

  def entry(_), do: []
end
