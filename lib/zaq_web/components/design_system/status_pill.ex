defmodule ZaqWeb.Components.DesignSystem.StatusPill do
  @moduledoc """
  Design-system classes for status pills across BO surfaces.

  Returns `zaq-pill` plus `zaq-text-caption` and a tone modifier (`zaq-pill--*`).
  Use `status_pill_classes/1` for ingestion job statuses, workflow lifecycle labels,
  workflow run / step-run statuses, and UI pseudo-labels (`"stale"`, `"ingested"`).
  Use `folder_count_pill_classes/1` for folder aggregate chips.

  Access-column chips (shared / public) use `zaq-pill` with `zaq-pill--shared` or
  `zaq-pill--public` in HEEX — see `assets/css/styles.css`.
  """

  @pill_base ~w(zaq-pill zaq-text-caption)

  @doc """
  Class list for a status string or UI-only status label.
  """
  # Workflow lifecycle
  def status_pill_classes("draft"), do: @pill_base ++ ~w(zaq-pill--warning)
  def status_pill_classes("active"), do: @pill_base ++ ~w(zaq-pill--success)
  def status_pill_classes("archived"), do: @pill_base ++ ~w(zaq-pill--elevated)
  # Ingestion jobs
  def status_pill_classes("pending"), do: @pill_base ++ ~w(zaq-pill--elevated)
  def status_pill_classes("processing"), do: @pill_base ++ ~w(zaq-pill--accent)
  def status_pill_classes("completed"), do: @pill_base ++ ~w(zaq-pill--success)
  def status_pill_classes("completed_with_errors"), do: @pill_base ++ ~w(zaq-pill--warning)
  def status_pill_classes("failed"), do: @pill_base ++ ~w(zaq-pill--danger)
  def status_pill_classes("cancelled"), do: @pill_base ++ ~w(zaq-pill--elevated)
  def status_pill_classes("stale"), do: @pill_base ++ ~w(zaq-pill--warning)
  def status_pill_classes("ingested"), do: @pill_base ++ ~w(zaq-pill--success)
  # Workflow runs and step runs
  def status_pill_classes("running"), do: @pill_base ++ ~w(zaq-pill--accent)
  def status_pill_classes("waiting"), do: @pill_base ++ ~w(zaq-pill--warning)
  def status_pill_classes("paused"), do: @pill_base ++ ~w(zaq-pill--elevated)
  def status_pill_classes("interrupted"), do: @pill_base ++ ~w(zaq-pill--warning)
  def status_pill_classes("failed_fatal"), do: @pill_base ++ ~w(zaq-pill--danger)
  def status_pill_classes("skipped"), do: @pill_base ++ ~w(zaq-pill--elevated)
  def status_pill_classes(_), do: @pill_base ++ ~w(zaq-pill--elevated)

  @doc """
  Folder row aggregate `ingested/total` chip: all files ingested vs partial progress.
  """
  def folder_count_pill_classes(true), do: @pill_base ++ ~w(zaq-pill--success)
  def folder_count_pill_classes(false), do: @pill_base ++ ~w(zaq-pill--warning)
end
