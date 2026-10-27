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
          challenge: %{
            type: :verification_code,
            uri: "https://auth.openai.com/codex/device",
            code: "ABCD-<EFGH>",
            expires_at: ~U[2026-10-09 12:15:00Z]
          }
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

  test "normalized QR renders local modules, never raw payload, and confirmation is escaped" do
    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "linked-device",
        attempt: %{status: "pending", challenge: %{type: :qr, value: "PRIVATE_QR_PAYLOAD"}}
      )

    assert html =~ "<svg"
    refute html =~ "PRIVATE_QR_PAYLOAD"
    assert html =~ ~s(aria-live="polite")

    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "linked-device",
        attempt: %{
          status: "confirm",
          confirmation: %{external_id: "+1234", display_name: "<account>"}
        }
      )

    assert html =~ "Confirm to create this channel"
    assert html =~ "&lt;account&gt;"
    assert html =~ ~s(id="linked-device-account-id")
    refute html =~ "<svg"
  end

  test "terminal and malformed challenges cannot retain QR or unsafe links" do
    for attempt <- [
          %{status: "expired", challenge: %{type: :qr, value: "OLD_QR"}},
          %{status: "pending", challenge: %{type: :qr, value: String.duplicate("q", 2049)}},
          %{
            status: "pending",
            challenge: %{type: :verification_code, uri: "javascript:alert(1)", code: "CODE"}
          }
        ] do
      html = render_component(&DeviceSignIn.device_sign_in/1, id: "device", attempt: attempt)
      refute html =~ "<svg"
      refute html =~ "javascript:"
      refute html =~ "OLD_QR"
    end
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

  test "initializing state exposes no instructions and remains in progress" do
    attempt = %{
      status: "initializing",
      user_code: "PRIVATE_CODE",
      verification_uri: "https://private.example.test"
    }

    html = render_component(&DeviceSignIn.device_sign_in/1, id: "device", attempt: attempt)
    assert html =~ "Starting sign-in"
    refute html =~ "PRIVATE_CODE"
    refute html =~ "private.example.test"
    assert DeviceSignIn.in_progress?(attempt)
    assert DeviceSignIn.in_progress?(%{status: "pending"})
    refute DeviceSignIn.in_progress?(nil)
    refute DeviceSignIn.in_progress?(%{status: "cancelled"})
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

  test "unavailable observation has restart guidance without old provider instructions" do
    html =
      render_component(&DeviceSignIn.device_sign_in/1,
        id: "device",
        attempt: %{status: "unavailable", user_code: "OLD_CODE"}
      )

    assert html =~ "This sign-in is no longer available. Start again."
    refute html =~ "OLD_CODE"
    refute html =~ "Open in new tab"
    refute DeviceSignIn.in_progress?(%{status: "unavailable"})
  end
end
