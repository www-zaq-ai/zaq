defmodule Zaq.Engine.Notifications.WelcomeEmail do
  @moduledoc """
  Builds and delivers welcome emails to newly created users via the notification center.
  """

  alias Zaq.Accounts
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.Notification

  @doc """
  Sends a welcome email to the user with their login URL through the notification center.
  Returns `{:ok, :dispatched}`, `{:ok, :skipped}`, or `{:ok, :skipped}` when the user
  has no email address.
  """
  @spec deliver(Accounts.User.t()) :: {:ok, :dispatched} | {:ok, :skipped}
  def deliver(%{email: email}) when email in [nil, ""], do: {:ok, :skipped}

  def deliver(user) do
    base_url = Application.get_env(:zaq, :base_url, "http://localhost:4000")
    login_url = "#{base_url}/bo/login"

    {:ok, notification} =
      Notification.build(%{
        recipient_channels: [%{platform: "email", identifier: user.email, preferred: true}],
        sender: "system",
        subject: "Welcome to ZAQ — your account is ready",
        body: build_text_body(user.username, login_url),
        html_body: build_html_body(user.username, login_url),
        recipient_name: user.username,
        recipient_ref: {:user, user.id}
      })

    Notifications.notify(notification)
  end

  defp build_text_body(username, login_url) do
    """
    Hi #{username},

    Your ZAQ account has been created. You can log in at:

    #{login_url}

    You will be asked to change your password on first login.

    — The ZAQ Team
    """
  end

  defp build_html_body(username, login_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: monospace; background: #f8fafc; padding: 40px 0; margin: 0;">
      <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 16px; border: 1px solid #e2e8f0; overflow: hidden;">
        <div style="background: #2d3e50; padding: 32px; text-align: center;">
          <h1 style="color: white; margin: 0; font-size: 18px; letter-spacing: 1px;">ZAQ BACK OFFICE</h1>
          <p style="color: #22d3ee; margin: 8px 0 0; font-size: 11px; letter-spacing: 2px; text-transform: uppercase;">Welcome</p>
        </div>
        <div style="padding: 40px 32px;">
          <p style="color: #475569; font-size: 14px; margin: 0 0 16px;">Hi <strong>#{username}</strong>,</p>
          <p style="color: #475569; font-size: 14px; margin: 0 0 24px;">
            Your ZAQ account has been created. Click the button below to log in.
            You will be asked to set a new password on your first login.
          </p>
          <div style="text-align: center; margin: 32px 0;">
            <a href="#{login_url}"
               style="display: inline-block; background: #22d3ee; color: #0f172a; padding: 14px 32px; border-radius: 12px; text-decoration: none; font-weight: bold; font-size: 13px; letter-spacing: 1px; text-transform: uppercase;">
              Log In to ZAQ
            </a>
          </div>
          <p style="color: #94a3b8; font-size: 12px; margin: 24px 0 0;">
            If you did not expect this email, please contact your administrator.
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
