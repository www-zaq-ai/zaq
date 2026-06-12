defmodule ZaqWeb.Components.DesignSystem.StatusPill do
  @moduledoc """
  Tailwind class strings for ingestion job status pills (BO jobs panel).
  """

  def status_color("pending"), do: "bg-black/5 text-black/40"
  def status_color("processing"), do: "bg-amber-100 text-amber-600"
  def status_color("completed"), do: "bg-emerald-100 text-emerald-700"
  def status_color("completed_with_errors"), do: "bg-orange-100 text-orange-700"
  def status_color("failed"), do: "bg-red-100 text-red-600"
  def status_color(_), do: "bg-black/5 text-black/30"
end
