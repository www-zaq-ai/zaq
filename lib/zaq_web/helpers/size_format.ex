defmodule ZaqWeb.Helpers.SizeFormat do
  @moduledoc """
  Shared byte-size formatting helpers for BO pages.
  """

  @doc """
  Formats a byte count using B/KB/MB units.
  """
  def format_size(nil), do: "—"
  def format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
