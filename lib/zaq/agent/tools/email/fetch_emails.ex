defmodule Zaq.Agent.Tools.Email.FetchEmails do
  @moduledoc """
  Connects to IMAP, fetches all unseen emails from a mailbox, and returns them.

  Returns `%{emails: [...], count: n}`. An empty list means no unseen messages.
  Expects `imap_config` to be a normalized map from `ImapConfigHelpers.normalize_bridge_config/1`.
  """

  use Jido.Action,
    name: "fetch_emails",
    schema: [
      imap_config: [type: :any, required: true],
      mailbox: [type: :string, default: "INBOX"]
    ]

  require Logger

  alias Zaq.Channels.EmailBridge.ImapAdapter

  @impl true
  def run(%{imap_config: imap_config} = params, _context) do
    mailbox = Map.get(params, :mailbox, "INBOX")

    task =
      Task.async(fn ->
        with {:ok, client} <- ImapAdapter.connect(imap_config, mailbox) do
          emails = collect_unseen(client, mailbox)
          ImapAdapter.disconnect(client)
          {:ok, emails}
        end
      end)

    case Task.await(task, 30_000) do
      {:ok, emails} ->
        count = length(emails)

        logs = [
          %{
            level: "info",
            message: "Fetched #{count} unseen email(s) from #{mailbox}",
            metadata: %{mailbox: mailbox, count: count}
          }
        ]

        {:ok, %{emails: emails, count: count}, logs: logs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_unseen(client, mailbox) do
    {:ok, acc} = Agent.start_link(fn -> [] end)

    ImapAdapter.fetch_unseen(client, mailbox, fn email ->
      Agent.update(acc, fn list -> [email | list] end)
    end)

    emails = acc |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(acc)
    emails
  end
end
