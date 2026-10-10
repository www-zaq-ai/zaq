defmodule Storybook.Components.DesignSystem.DeviceSignIn do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn

  def description, do: "Shared BO/People device-sign-in instructions, new-tab link and restart states."

  def render(assigns) do
    ~H"""
    <div class="zaq-layout-stack">
      <DeviceSignIn.device_sign_in id="device-pending" attempt={%{
        status: "pending", verification_uri: "https://auth.openai.com/codex/device",
        user_code: "ABCD-EFGH", expires_at: ~U[2026-10-09 12:15:00Z]
      }} />
      <DeviceSignIn.device_sign_in
        :for={status <- ["initializing", "active", "interrupted", "expired", "denied", "cancelled", "failed", "unavailable"]}
        id={"device-" <> status}
        attempt={%{status: status}}
      />
    </div>
    """
  end
end
