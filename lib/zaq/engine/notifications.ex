defmodule Zaq.Engine.Notifications do
  @moduledoc """
  Notification center for ZAQ.

  Routes notifications to all available channels for a given user.
  Currently supports: email (via SMTP).

  ## Usage

      Zaq.Engine.Notifications.notify(user, %{
        subject: "Welcome to ZAQ",
        body: "Your account has been created."
      })

  ## Adding channels

  Implement `Zaq.Engine.NotificationChannel` and add the module to `channels/0`.

  ## SMTP Configuration (env vars)

  | Variable          | Default         | Description                  |
  |-------------------|-----------------|------------------------------|
  | SMTP_RELAY        | —               | SMTP server hostname         |
  | SMTP_PORT         | 587             | SMTP port                    |
  | SMTP_USERNAME     | —               | SMTP auth username           |
  | SMTP_PASSWORD     | —               | SMTP auth password           |
  | SMTP_FROM_EMAIL   | noreply@zaq.local | Sender email address       |
  | SMTP_FROM_NAME    | ZAQ             | Sender display name          |
  | SMTP_TLS          | enabled         | TLS mode: enabled/always/never |
  """

  require Logger

  alias Zaq.Engine.Notifications.EmailChannel

  @type user :: Zaq.Accounts.User.t()
  @type notification :: %{subject: String.t(), body: String.t()}

  @doc """
  Sends a notification to the user on all available channels.

  Returns a map of `%{channel_module => :ok | {:error, reason}}`.
  """
  @spec notify(user(), notification()) :: %{module() => :ok | {:error, term()}}
  def notify(user, notification) do
    channels()
    |> Enum.filter(& &1.available?(user))
    |> Map.new(fn channel ->
      result =
        try do
          channel.send_notification(user, notification)
        rescue
          e -> {:error, Exception.message(e)}
        end

      if result != :ok do
        Logger.warning(
          "[Notifications] #{inspect(channel)} failed for user #{user.id}: #{inspect(result)}"
        )
      end

      {channel, result}
    end)
  end

  @doc """
  Returns the list of registered notification channel adapters.
  """
  @spec channels() :: [module()]
  def channels, do: [EmailChannel]
end
