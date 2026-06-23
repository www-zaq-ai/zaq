defmodule Storybook.Ingestion do
  @moduledoc """
  BO ingestion UI: file browser, volume selector, jobs panel, and related modals.
  """
  use PhoenixStorybook.Index

  def folder_name, do: "Ingestion"
  def folder_index, do: 9

  def entry("ingestion_file_browser_header"),
    do: [name: "Ingestion File Browser Header", index: 1]

  def entry("ingestion_file_grid_view"),
    do: [name: "Ingestion File Grid View", index: 2]

  def entry("ingestion_file_icon"),
    do: [name: "Ingestion File Icon", index: 3]

  def entry("ingestion_file_list_view"),
    do: [name: "Ingestion File List View", index: 4]

  def entry("ingestion_jobs_panel"),
    do: [name: "Ingestion Jobs Panel", index: 5]

  def entry("ingestion_volume_selector"),
    do: [name: "Ingestion Volume Selector", index: 6]

  def entry("modal_add_raw"),
    do: [name: "Modal Add Raw", index: 7]

  def entry("modal_delete"),
    do: [name: "Modal Delete", index: 8]

  def entry("modal_delete_selected"),
    do: [name: "Modal Delete Selected", index: 9]

  def entry("modal_move"),
    do: [name: "Modal Move", index: 10]

  def entry("modal_new_folder"),
    do: [name: "Modal New Folder", index: 11]

  def entry("modal_rename"),
    do: [name: "Modal Rename", index: 12]

  def entry("modal_share"),
    do: [name: "Modal Share", index: 13]

  def entry(_), do: []
end
