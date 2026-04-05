defmodule Zaq.Channels.EmailBridge do
  @moduledoc """
  Bridge for the email channel.

  Delivers `%Outgoing{}` via SMTP using the notification SMTP implementation.
  Connection details are not required — SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp`.

  `to_internal/2` is a stub for future inbound email parsing.
  """

  alias Zaq.Engine.Messages.Outgoing

  @doc "Stub for future inbound email parsing — not yet implemented."
  @spec to_internal(map(), map()) :: {:error, :not_implemented}
  def to_internal(_params, _connection_details), do: {:error, :not_implemented}

  @doc """
  Delivers `%Outgoing{}` as an email to `outgoing.channel_id` (the recipient address).

  Reads subject and html_body from `outgoing.metadata` (keys `:subject` / `"subject"`
  and `:html_body` / `"html_body"`). Falls back to a default subject if missing.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    alias Zaq.Engine.Notifications.EmailNotification

    subject = get_meta(outgoing.metadata, "subject", :subject) || "Notification from ZAQ"
    html_body = get_meta(outgoing.metadata, "html_body", :html_body)
    payload = %{"subject" => subject, "body" => outgoing.body, "html_body" => html_body}

    EmailNotification.send_notification(outgoing.channel_id, payload, %{})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Handles both atom and string-keyed metadata (Oban args arrive as string keys).
  defp get_meta(metadata, string_key, atom_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end
end
