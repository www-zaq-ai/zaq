defmodule Zaq.Agent.Tools.Email.NotifyEmptyMailbox do
  @moduledoc """
  Terminal action for the empty-mailbox branch.
  Logs that no emails were found and sends a notification email to the configured address.
  """

  use Jido.Action,
    name: "notify_empty_mailbox",
    schema: [
      notify_address: [type: :string, required: true]
    ]

  require Logger

  alias Zaq.Engine.Notifications.EmailNotification

  @impl true
  def run(%{notify_address: notify_address}, _context) do
    Logger.info("[NotifyEmptyMailbox] Mailbox is empty — notifying #{notify_address}")

    payload = %{
      "subject" => "Mailbox check — no new emails",
      "body" => "The scheduled email check ran but found no unseen messages in the mailbox."
    }

    metadata = %{"email_body" => payload["body"], "headers" => %{}}

    case EmailNotification.send_notification(notify_address, payload, metadata) do
      :ok ->
        Logger.info("[NotifyEmptyMailbox] Notification sent to #{notify_address}")

        {:ok, %{status: :skipped, notified: true},
         logs: [%{level: "info", message: "Notification sent to #{notify_address}"}]}

      {:error, reason} ->
        Logger.error("[NotifyEmptyMailbox] Failed to notify: #{inspect(reason)}")

        {:ok, %{status: :skipped, notified: false},
         logs: [%{level: "warn", message: "Notification failed: #{inspect(reason)}"}]}
    end
  end
end
