defmodule Zaq.Agent.Tools.Email.NotifyEmptyMailbox do
  @moduledoc """
  Terminal action for the empty-mailbox branch.
  Logs that no emails were found and sends a notification email to the configured address.
  """

  # THIS JIDO ACTION IS FOR TESTING PURPOSES
  # IT WILL GET REMOVED IN THE FUTURE
  use Jido.Action,
    name: "notify_empty_mailbox",
    schema: [
      notify_address: [type: :string, required: true]
    ],
    output_schema: [
      status: [type: :atom, required: true],
      notified: [type: :boolean, required: true]
    ]

  require Logger

  alias Zaq.Engine.Notifications.EmailNotification

  use Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_failure(error, _context) do
    Logger.warning("[NotifyEmptyMailbox] step failed: #{inspect(error)}")
    :ok
  end

  @impl true
  def run(%{notify_address: notify_address}, _context) do
    subject = "Mailbox check — no new emails"
    body = "The scheduled email check ran but found no unseen messages in the mailbox."

    Logger.info(
      "[NotifyEmptyMailbox] Mailbox empty — sending notification to=#{notify_address} subject=#{inspect(subject)}"
    )

    payload = %{"subject" => subject, "body" => body}
    metadata = %{"email_body" => body, "headers" => %{}}

    task =
      Task.async(fn -> EmailNotification.send_notification(notify_address, payload, metadata) end)

    case Task.await(task, 30_000) do
      :ok ->
        Logger.info("[NotifyEmptyMailbox] Notification sent to=#{notify_address}")

        {:ok, %{status: :skipped, notified: true},
         logs: [
           %{
             level: "info",
             message: "Notification sent to #{notify_address}",
             metadata: %{notify_address: notify_address, subject: subject}
           }
         ]}

      {:error, reason} ->
        Logger.error(
          "[NotifyEmptyMailbox] Delivery failed to=#{notify_address} reason=#{inspect(reason)}"
        )

        {:ok, %{status: :skipped, notified: false},
         logs: [
           %{
             level: "warn",
             message: "Notification failed for #{notify_address}: #{inspect(reason)}",
             metadata: %{notify_address: notify_address, reason: inspect(reason)}
           }
         ]}
    end
  end
end
