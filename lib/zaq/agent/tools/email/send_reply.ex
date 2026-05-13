defmodule Zaq.Agent.Tools.Email.SendReply do
  @moduledoc """
  Delivers each draft via Swoosh/SMTP.
  SMTP config is read at runtime from the `email:smtp` channel config.
  Returns a summary: `%{sent: n, failed: n, results: [...]}`.
  """

  use Jido.Action,
    name: "send_reply",
    schema: [
      drafts: [type: :any, required: true]
    ]

  require Logger

  alias Zaq.Engine.Notifications.EmailNotification

  @impl true
  def run(%{drafts: drafts}, _context) do
    results =
      Enum.map(drafts, fn draft ->
        payload = %{"subject" => draft.subject, "body" => draft.draft}

        metadata = %{
          "email_body" => draft.draft,
          "headers" => threading_headers(draft[:message_id])
        }

        recipient =
          if draft.to_name, do: {draft.to_name, draft.to_address}, else: draft.to_address

        case EmailNotification.send_notification(recipient, payload, metadata) do
          :ok ->
            Logger.info("[SendReply] Sent to=#{draft.to_address}")
            %{to: draft.to_address, status: :sent}

          {:error, reason} ->
            Logger.error(
              "[SendReply] SMTP failed to=#{draft.to_address} reason=#{inspect(reason)}"
            )

            %{to: draft.to_address, status: :failed, reason: inspect(reason)}
        end
      end)

    sent = Enum.count(results, &(&1.status == :sent))
    failed = Enum.count(results, &(&1.status == :failed))

    logs = [
      %{
        level: if(failed > 0, do: "warn", else: "info"),
        message: "Sent #{sent} email(s), #{failed} failed",
        metadata: %{sent: sent, failed: failed}
      }
    ]

    {:ok, %{sent: sent, failed: failed, results: results}, logs: logs}
  end

  defp threading_headers(nil), do: %{}
  defp threading_headers(id), do: %{"In-Reply-To" => id, "References" => id}
end
