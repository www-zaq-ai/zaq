defmodule Zaq.Engine.NotificationAdapter do
  @moduledoc """
  Behaviour contract for notification channel adapters.

  Each adapter is responsible for delivering a notification to a recipient
  via a specific platform (email, Mattermost, etc.).

  ## Implementing an adapter

      defmodule Zaq.Engine.Notifications.Adapters.MyAdapter do
        @behaviour Zaq.Engine.NotificationAdapter

        @impl true
        def platform, do: "my_platform"

        @impl true
        def send(identifier, payload, metadata), do: ...
      end
  """

  @doc ~S'Returns the platform string this adapter handles (e.g. "email", "mattermost").'
  @callback platform() :: String.t()

  @doc """
  Delivers the notification to the recipient.

  - `identifier` — platform-specific recipient address (email address, channel ID, etc.)
  - `payload` — map with `"subject"`, `"body"`, and optional `"html_body"` keys
  - `metadata` — serialisable map; may include `"on_reply"` instructions

  Returns `:ok` or `{:error, reason}`.
  """
  @callback send(identifier :: String.t(), payload :: map(), metadata :: map()) ::
              :ok | {:error, term()}
end
