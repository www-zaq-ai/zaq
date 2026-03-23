defmodule Zaq.Engine.NotificationAdapter do
  @moduledoc """
  Behaviour contract for notification channel adapters.

  Each adapter is responsible for delivering a notification to a recipient
  via a specific platform (email, Mattermost, etc.).

  The platform name is declared in the `@adapter_registry` of
  `Zaq.Engine.Notifications` — adapters do not need to self-identify.

  ## Implementing an adapter

      defmodule Zaq.Channels.Retrieval.MyPlatform.Notification do
        @behaviour Zaq.Engine.NotificationAdapter

        @impl true
        def send_notification(identifier, payload, metadata), do: ...
      end
  """

  @doc """
  Delivers the notification to the recipient.

  - `identifier` — platform-specific recipient address (email address, channel ID, etc.)
  - `payload` — map with `"subject"`, `"body"`, and optional `"html_body"` keys
  - `metadata` — serialisable map; may include `"on_reply"` instructions

  Returns `:ok` or `{:error, reason}`.
  """
  @callback send_notification(identifier :: String.t(), payload :: map(), metadata :: map()) ::
              :ok | {:error, term()}
end
