defmodule ZaqWeb.Components.DesignSystem.StatusBadge do
  @moduledoc """
  Connection diagnostic status chip for BO diagnostics and similar surfaces.

  Accepts `:idle`, `:loading`, `:ok`, or `{:error, reason}` (reason is shown as "error" in the pill;
  use the parent card for full error text).
  """

  use Phoenix.Component

  attr :status, :any, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      :if={@status == :idle}
      class="zaq-pill zaq-text-caption zaq-pill--elevated"
    >
      idle
    </span>
    <span
      :if={@status == :loading}
      class="zaq-pill zaq-text-caption zaq-pill--accent zaq-pill--pulse"
    >
      testing…
    </span>
    <span
      :if={@status == :ok}
      class="zaq-pill zaq-text-caption zaq-pill--success"
    >
      ✓ connected
    </span>
    <span
      :if={is_tuple(@status) and elem(@status, 0) == :error}
      class="zaq-pill zaq-text-caption zaq-pill--danger"
    >
      ✗ error
    </span>
    """
  end
end
