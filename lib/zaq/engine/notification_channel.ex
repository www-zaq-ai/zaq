defmodule Zaq.Engine.NotificationChannel do
  @moduledoc """
  Behaviour contract for notification channel adapters.

  Each adapter is responsible for delivering a notification to a user
  via a specific channel (email, Slack, etc.).

  ## Implementing an adapter

      defmodule Zaq.Engine.Notifications.MyChannel do
        @behaviour Zaq.Engine.NotificationChannel

        @impl true
        def available?(user), do: not is_nil(user.some_field)

        @impl true
        def send_notification(user, notification), do: ...
      end
  """

  @type user :: Zaq.Accounts.User.t()
  @type notification :: %{subject: String.t(), body: String.t(), html_body: String.t() | nil}

  @doc """
  Returns true if this channel can deliver to the given user
  (e.g. user has an email address configured).
  """
  @callback available?(user()) :: boolean()

  @doc """
  Delivers the notification to the user via this channel.
  Returns `:ok` or `{:error, reason}`.
  """
  @callback send_notification(user(), notification()) :: :ok | {:error, term()}
end
