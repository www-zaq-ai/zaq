defmodule Storybook.Modals do
  @moduledoc """
  Back-office modal primitives (`ZaqWeb.Components.BOModal`) and modal compositions.
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Modals"
  def folder_index, do: 5

  def entry("bo_modal"), do: [name: "BO Modal", index: 0]
  def entry("file_preview_modal"), do: [name: "File Preview Modal", index: 1]
  def entry("file_preview"), do: [name: "File Preview", index: 2]
  def entry("channel_capabilities"), do: [name: "Channel Capabilities", index: 3]
end
