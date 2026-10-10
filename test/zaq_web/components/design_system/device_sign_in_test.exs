defmodule ZaqWeb.Components.DesignSystem.DeviceSignInTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn

  test "verification URL has an adjacent safe new-tab button and escaped code" do
    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "device",
        attempt: %{
          status: "pending",
          verification_uri: "https://auth.openai.com/codex/device",
          user_code: "ABCD-<EFGH>",
          expires_at: ~U[2026-10-09 12:15:00Z]
        }
      )

    assert html =~ "https://auth.openai.com/codex/device"
    assert html =~ "Open in new tab"
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    assert html =~ "ABCD-&lt;EFGH&gt;"
    refute html =~ "ABCD-<EFGH>"
    assert html =~ "12:15 UTC"
  end

  test "terminal states omit codes and provide explicit recovery guidance" do
    for status <- ["expired", "denied", "failed", "interrupted"] do
      html =
        render_component(&DeviceSignIn.device_sign_in/1, id: "device", attempt: %{status: status})

      assert html =~ "Start a new device sign-in"
      refute html =~ "Sign-in code"
      refute html =~ "target="
    end
  end

  test "active state confirms completion without pending-flow content" do
    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "device",
        attempt: %{status: "active"}
      )

    assert html =~ ~s(id="device")
    assert html =~ "Device sign-in completed. Your credential is connected."
    refute html =~ "Sign-in code"
    refute html =~ "Open in new tab"
    refute html =~ "target="
    refute html =~ "Start a new device sign-in"
  end
end
