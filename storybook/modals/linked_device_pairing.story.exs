defmodule Storybook.Modals.LinkedDevicePairing do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.LinkedDevicePairing

  def description, do: "Shared linked-device pairing, expiry and connected states. Example QR is not a real credential."

  def render(assigns) do
    ~H"""
    <div class="zaq-layout-stack">
      <div :for={{phase, summary} <- [{:pairing, "Scan the code"}, {:confirm, "Confirm this account"}, {:connected, "Device connected"}, {:expired, "Pairing code expired"}, {:failed, "Connection failed"}]} class="zaq-modal-preview relative h-96">
        <LinkedDevicePairing.modal cancel_connection={phase != :confirm} id={"pairing-#{phase}"} name="Support account" provider="Example provider"
          status={%{identity: %{display_name: "Support", phone_number: "+15550001"}, phase: phase, summary: summary, qr: if(phase == :pairing, do: "storybook-example", else: nil)}} />
      </div>
    </div>
    """
  end
end
