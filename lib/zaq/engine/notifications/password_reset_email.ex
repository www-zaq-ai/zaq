defmodule Zaq.Engine.Notifications.PasswordResetEmail do
  @moduledoc """
  Builds and delivers password reset emails via the notification center.
  """

  alias Zaq.Accounts
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.Notification

  @doc """
  Sends a password reset email to the user if they have an email address.
  Returns `{:ok, :dispatched}`, `{:ok, :skipped}`, or `{:error, :no_email}`.
  """
  @spec deliver(Accounts.User.t(), String.t()) ::
          {:ok, :dispatched} | {:ok, :skipped} | {:error, :no_email}
  def deliver(%{email: nil}, _token), do: {:error, :no_email}
  def deliver(%{email: ""}, _token), do: {:error, :no_email}

  def deliver(user, token) do
    base_url = Application.get_env(:zaq, :base_url, "http://localhost:4000")
    reset_url = "#{base_url}/bo/reset-password/#{token}"

    {:ok, notification} =
      Notification.build(%{
        recipient_channels: [%{platform: "email", identifier: user.email, preferred: true}],
        sender: "system",
        subject: "Reset your ZAQ password",
        body: build_text_body(user.username, reset_url),
        html_body: build_html_body(user.username, reset_url),
        recipient_name: user.username,
        recipient_ref: {:user, user.id}
      })

    Notifications.notify(notification)
  end

  defp build_text_body(username, reset_url) do
    """
    Hi #{username},

    Someone requested a password reset for your ZAQ account.
    Click the link below to set a new password (valid for 1 hour):

    #{reset_url}

    If you did not request this, you can safely ignore this email.

    — The ZAQ Team
    """
  end

  defp build_html_body(username, reset_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: monospace; background: #f8fafc; padding: 40px 0; margin: 0;">
      <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 16px; border: 1px solid #e2e8f0; overflow: hidden;">
        <div style="background: #2d3e50; padding: 32px; text-align: center;">
          <h1 style="color: white; margin: 0; font-size: 18px; letter-spacing: 1px;">ZAQ BACK OFFICE</h1>
          <p style="color: #22d3ee; margin: 8px 0 0; font-size: 11px; letter-spacing: 2px; text-transform: uppercase;">Password Reset</p>
        </div>
        <div style="padding: 40px 32px;">
          <p style="color: #475569; font-size: 14px; margin: 0 0 16px;">Hi <strong>#{username}</strong>,</p>
          <p style="color: #475569; font-size: 14px; margin: 0 0 24px;">
            Someone requested a password reset for your ZAQ account.
            Click the button below to set a new password. This link is valid for <strong>1 hour</strong>.
          </p>
          <div style="text-align: center; margin: 32px 0;">
            <a href="#{reset_url}"
               style="display: inline-block; background: #22d3ee; color: #0f172a; padding: 14px 32px; border-radius: 12px; text-decoration: none; font-weight: bold; font-size: 13px; letter-spacing: 1px; text-transform: uppercase;">
              Reset Password
            </a>
          </div>
          <p style="color: #94a3b8; font-size: 12px; margin: 24px 0 0;">
            If you did not request this, you can safely ignore this email.
          </p>
        </div>
        <div style="background: #f8fafc; padding: 16px 32px; text-align: center; border-top: 1px solid #e2e8f0;">
          <p style="color: #94a3b8; font-size: 11px; margin: 0;">&copy; #{Date.utc_today().year} ZAQ &middot; AI for fresh company knowledge</p>
        </div>
      </div>
    </body>
    </html>
    """
  end
end
